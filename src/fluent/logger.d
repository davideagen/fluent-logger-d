// Written in the D programming language.

/**
 * Fluent logger implementation.
 *
 * Fluentd is a missing event collector.
 *
 * Example:
 * -----
 * struct Event
 * {
 *     string text = "This is D";
 *     long   id   = 0;
 * }
 *
 * // Create a configuration
 * FluentLogger.Configuration conf;
 * conf.host = "backend1";
 *
 * // Create a logger with tag prefix and configuration
 * auto logger = new FluentLogger("app", conf);
 *
 * // Write Event object with "test" tag to Fluentd 
 * logger.post("test", Event());
 * // Fluentd accepts {"text":"This is D","id":0} at "app.test" input
 * -----
 *
 * See_Also:
 *  $(LINK2 http://fluentd.org/, Welcome to Fluentd’s documentation!)
 *
 * Copyright: Copyright Masahiro Nakagawa 2012-.
 * License:   <a href="http://www.apache.org/licenses/LICENSE-2.0">Apache License, Version 2.0</a>.
 * Authors:   Masahiro Nakagawa
 */

module fluent.logger;

private import core.sync.mutex;
private import std.array;
private import std.datetime : Clock, SysTime;
private import std.socket : getAddress, lastSocketError, ProtocolType, Socket,
                            SocketException, SocketShutdown, SocketType, TcpSocket;

debug import std.stdio;  // TODO: replace with std.log

private import msgpack;


/**
 * Base class for Fluent loggers
 */
abstract class Logger
{
    // should be changed to interface?
  protected:
    immutable string prefix_;


  public:
    @safe
    this(in string prefix)
    {
        prefix_ = prefix;
    }

    @property
    const(ubyte[]) pendings() const;

    void close();

    bool post(T)(in string tag, auto ref const T record)
    {
        return post(tag, Clock.currTime(), record);
    }

    bool post(T)(in string tag, in SysTime time, auto ref const T record)
    {
        auto completeTag = prefix_.length ? prefix_ ~ "." ~ tag : tag;
        return write(pack!true(completeTag, time.toUnixTime(), record));
    }

    bool write(in ubyte[] data);
}


class Tester : Logger
{
  private:
    ubyte[] buffer_;  // should have limit?
    Mutex mutex_;


  public:
    /* @safe */
    this(in string prefix)
    {
        super(prefix);

        mutex_ = new Mutex();
    }

    @property
    override const(ubyte[]) pendings() const
    {
        synchronized(mutex_) {
            return buffer_;
        }
    }

    override void close()
    {
        buffer_ = null;
    }

    override bool write(in ubyte[] data)
    {
        synchronized(mutex_) {
            buffer_ ~= data;
        }

        return true;
    }
}


/**
 * $(D FluentLogger) is a $(D Fluentd) client
 */
class FluentLogger : Logger
{
  private import std.buffer.scopebuffer : scopeBuffer, ScopeBuffer;
  public:
    /**
     * FluentLogger configuration
     */
    struct Configuration
    {
        string host = "localhost";
        ushort port = 24224;
        /* 
         * uint instead of size_t because that's the limit of ScopeBuffer
         * which is used to store the actual data.
         */
        uint initialBufferSize = 256 * 1024;
    }


  private:
    immutable Configuration config_;

    //Appender!(ubyte[]) buffer_;  // Appender's qualifiers are broken...
    ScopeBuffer!ubyte buffer_ = void;
    TcpSocket  socket_;

    // for reconnection
    uint    errorNum_;
    SysTime errorTime_;

    // for multi-threading
    Mutex mutex_;


  public:
    /* @safe */
    this(in string prefix, in Configuration config)
    {
        super(prefix);

        config_ = config;
        mutex_ = new Mutex();

        ubyte tmpBuf[];
        tmpBuf.reserve = config.initialBufferSize;
        buffer_ = scopeBuffer(tmpBuf);
    }

    ~this()
    {
        close();
		buffer_.free();
    }

    /**
     * Returns:
     *  A slice into the buffer of data waiting to be sent that is only
     *  valid until the next post() or write().
     */
    @property
    override const(ubyte[]) pendings() const
    {
        synchronized(mutex_) {
            return buffer_[];
        }
    }

    override void close()
    {
        synchronized(mutex_) {
            if (socket_ !is null) {
                if (buffer_.length > 0) {
                    try {
                        send(buffer_[]);
                        buffer_.length = 0;
                    } catch (const SocketException e) {
                        debug { writeln("Failed to flush logs. ", buffer_.length, " bytes not sent."); }
                    }
                }

                socket_.shutdown(SocketShutdown.BOTH);
                socket_.close();
                socket_ = null;
            }
        }
    }

    override bool write(in ubyte[] data)
    {
        synchronized(mutex_) {
            buffer_.put(data);
            if (!canWrite())
                return false;

            try {
                send(buffer_[]);
                buffer_.length = 0;
            } catch (SocketException e) {
                clearSocket();
                throw e;
            }
        }

        return true;
    }


  private:
    @trusted
    void connect()
    {
        auto addresses = getAddress(config_.host, config_.port);
        if (addresses.length == 0)
            throw new Exception("Failed to resolve host: host = " ~ config_.host);

        // hostname sometimes provides many address informations
		foreach (i, ref address; addresses) {
            try {
                auto socket = new TcpSocket(address);
				socket_    = socket;
                errorNum_  = 0;
                errorTime_ = SysTime.init;

                debug { writeln("Connected to: host = ", config_.host, ", port = ", config_.port); }

                return;
            } catch (SocketException e) {
                clearSocket();

                // If all hosts can't be connected, raises an exeception
                if (i == addresses.length - 1) {
                    errorNum_++;
                    errorTime_ = Clock.currTime();

                    throw e;
                }
            }
        }
    }

    @trusted
    void send(in ubyte[] data)
    {
        if (socket_ is null)
            connect();

        auto bytesSent = socket_.send(data);
        if(bytesSent == Socket.ERROR)
        {
            throw new SocketException("Unable to send to socket. ", lastSocketError());
        }

        debug { writeln("Sent: ", data.length, " bytes"); }
    }
    
    void clearSocket()
    {
        // reconnection at send method.
        if (socket_ !is null) {
            try {
                socket_.close();
            } catch (SocketException e) {
                // ignore close exception.
            }
        }
        socket_ = null;
    }

    enum ReconnectionWaitingMax = 60u;

    /* @safe */ @trusted
    bool canWrite()
    {
        // prevent useless reconnection
        if (errorTime_ != SysTime.init) {
            // TODO: more complex?
            uint secs = 2 ^^ errorNum_;
            if (secs > ReconnectionWaitingMax)
                secs = ReconnectionWaitingMax;

            if ((Clock.currTime() - errorTime_).get!"seconds"() < secs)
                return false;
        }

        return true;
    }
}
