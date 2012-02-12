// Written in the D programming language

/**
 * Prototype of new Socket module.
 *
 * TODO: more functions and DNS utilities
 *
 * Copyright: Copyright Masahiro Nakagawa 2012-.
 * License:   <a href="http://www.boost.org/LICENSE_1_0.txt">Boost License 1.0</a>.
 * Authors:   Masahiro Nakagawa, Christopher E. Miller
 */

module socket;

import core.memory;       // GC
import core.time;         // Duration
import core.stdc.errno;   // errno
import core.stdc.stdlib;  // alloca

import std.exception;  // enforce, enforceEx
import std.conv;       // to
import std.string;     // cmp, toStringz
import std.c.string;   // strlen, strerror, strerror_r, memset

version(unittest)
{
    import std.stdio;
}

version(Posix)
{
    version = BsdSockets;
}

version(Windows)
{
    // Need for using Socket functions.
    pragma(lib, "ws2_32.lib");
    pragma(lib, "wsock32.lib");

    import std.c.windows.windows;
    import std.c.windows.winsock;

    enum socket_t : SOCKET
    { 
        INVALID_SOCKET
    };

    private
    {
        enum _SocketError = SOCKET_ERROR;  /// Send or receive error code(SOCKET_ERROR).

        extern(Windows)
        {
            // compatible for Posix environment(from MSDN)
            enum _SS_PAD1SIZE = long.sizeof - short.sizeof;
            enum _SS_PAD2SIZE = 128 - short.sizeof - _SS_PAD1SIZE - long.sizeof;

            struct sockaddr_storage
            {
                short                ss_family;
                byte[_SS_PAD1SIZE] __ss_pad1;
                long               __ss_align;
                byte[_SS_PAD2SIZE] __ss_pad2;
            }


            union _inet_sock
            {
                sockaddr         base;
                sockaddr_in      v4;
                sockaddr_in6     v6;
                sockaddr_storage storage;
            }


            // placeholder for WSAStringToAddressA and WSAAddressToStringA
            struct WSAPROTOCOL_INFO { }
            alias WSAPROTOCOL_INFO* LPWSAPROTOCOL_INFO;

            int WSAStringToAddressA(const char*, int, LPWSAPROTOCOL_INFO, sockaddr*, int*);
            int WSAAddressToStringA(sockaddr*, int, LPWSAPROTOCOL_INFO, const char*, int*);

            alias int function(const char*, const char*, const addrinfo*, addrinfo**) getaddrinfo_t;
            alias void function(addrinfo*)                                            freeaddrinfo_t;
        }

        enum EAFNOSUPPORT = 10047;  // WSAEAFNOSUPPORT


        int lastError()
        {
            return WSAGetLastError();
        }


        // compatible for Posix environment
        int inet_pton(int af, const char* src, void* dst)
        {
            if (af != AF_INET && af != AF_INET6) {
                // unsupported address family
                setErrno(EAFNOSUPPORT);
                return -1;
            }

            _inet_sock addr;
            int        size = addr.sizeof;

            auto error = WSAStringToAddressA(src, af, null, &addr.base, &size);
            if (error)
                return 0;  // src is invalid notation.

            if (af == AF_INET) {
                *cast(in_addr*)dst  = addr.v4.sin_addr;
            } else {
                *cast(in6_addr*)dst = addr.v6.sin6_addr;
            }

            return 1;
        }


        // ditto
        char* inet_ntop(int af, const void* src, char* dst, int length)
        {
            if (af != AF_INET && af != AF_INET6) {
                // unsupported address family
                setErrno(EAFNOSUPPORT);
                return null;
            }

            _inet_sock addr;
            int        size;

            if (af == AF_INET) {
                size               = addr.v4.sizeof;
                addr.v4.sin_family = AF_INET;
                addr.v4.sin_addr   = *cast(typeof(addr.v4.sin_addr)*)src;
            } else {
                size                = addr.v6.sizeof;
                addr.v6.sin6_family = AF_INET6;
                addr.v6.sin6_addr   = *cast(typeof(addr.v6.sin6_addr)*)src;
            }

            auto error = WSAAddressToStringA(&addr.base, size, null, dst, &length);
            if (error)
                return null;  // src is invalid notation.

            return dst;
        }
    }
}
else version(BsdSockets)
{
    version(Posix)
    {
        version(linux)
        {
            import std.c.linux.socket;
        }
        else version(OSX)
        {
            import std.c.osx.socket;
        }
        else version(FreeBSD)
        {
            import std.c.freebsd.socket;
            import core.sys.posix.sys.select;
            import core.sys.posix.netinet.tcp;
            import core.sys.posix.netinet.in_;
            import core.sys.posix.sys.socket;

            private
            {
                enum SD_RECEIVE = SHUT_RD;
                enum SD_SEND    = SHUT_WR;
                enum SD_BOTH    = SHUT_RDWR;
            }
        }

        import core.sys.posix.fcntl;
        import core.sys.posix.unistd;
        import core.sys.posix.sys.time;
    }

    enum socket_t : int32_t
    { 
        init = -1
    }

    private
    {
        enum _SocketError = -1;  /// Send or receive error code(-1).

        // Why undefined?
        extern(C)
        {
            struct addrinfo
            {
                int       ai_flags; 
                int       ai_family;
                int       ai_socktype;
                int       ai_protocol;
                socklen_t ai_addrlen;
                version (linux)
                {
                    sockaddr* ai_addr;
                    char*     ai_canonname;
                }
                else
                {
                    char*     ai_canonname;
                    sockaddr* ai_addr;
                }
                addrinfo* ai_next;
            }

            int getaddrinfo(const char* node, const char* service, const addrinfo* hints, addrinfo** res);
            void freeaddrinfo(addrinfo* ai);

            alias typeof(&getaddrinfo)  getaddrinfo_t;
            alias typeof(&freeaddrinfo) freeaddrinfo_t;
        }

        int lastError()
        {
            return errno;
        }
    }
}
else
{
    static assert(false, "Non support environment");
}


private __gshared
{
    getaddrinfo_t  getaddrinfo_func;
    freeaddrinfo_t freeaddrinfo_func;
}


shared static this()
{
    version(Windows)
    {
        WSADATA wd;

        // Winsock will still load if an older version is present.
        // The version is just a request.
        int val = WSAStartup(0x2020, &wd);
        if (val) // Request Winsock 2.2 for IPv6.
            throw new SocketException("Unable to initialize socket library", val);

        // workaround for AddressInfo. dmd's lib doesn't have getaddrinfo functions.
        if (auto handle = GetModuleHandleA("ws2_32.dll")) {
            getaddrinfo_func  = cast(getaddrinfo_t) GetProcAddress(handle, "getaddrinfo");
            freeaddrinfo_func = cast(freeaddrinfo_t)GetProcAddress(handle, "freeaddrinfo");
        }
    }
    else
    {
        getaddrinfo_func  = &getaddrinfo;
        freeaddrinfo_func = &freeaddrinfo;
    }
}


shared static ~this()
{
    // Avoids FinalizeError. D's GC may call the destructor of objects after static destructors.
    GC.collect();

    version(Windows)
    {
        WSACleanup();
    }
}


/**
 * The communication domain used to resolve an address
 */
enum AddressFamily : int
{
    UNSPEC    = AF_UNSPEC,     ///
    UNIX      = AF_UNIX,       /// local communication
    INET      = AF_INET,       /// internet protocol version 4
    IPX       = AF_IPX,        /// novell IPX
    APPLETALK = AF_APPLETALK,  /// appletalk
    INET6     = AF_INET6,      /// internet protocol version 6
}


/**
 * Communication semantics
 */
enum SocketType : int
{
    ANY,                         /// emulates the Posix behavior of null
    STREAM    = SOCK_STREAM,     /// sequenced, reliable, two-way communication-based byte streams
    DGRAM     = SOCK_DGRAM,      /// connectionless, unreliable datagrams with a fixed maximum length; data may be lost or arrive out of order
    RAW       = SOCK_RAW,        /// raw protocol access
    RDM       = SOCK_RDM,        /// reliably-delivered message datagrams
    SEQPACKET = SOCK_SEQPACKET,  /// sequenced, reliable, two-way connection-based datagrams with a fixed maximum length
}


/**
 * Protocol
 */
enum ProtocolType : int
{
    ANY,                  /// emulates the Posix behavior of null
    IP   = IPPROTO_IP,    /// internet protocol version 4
    ICMP = IPPROTO_ICMP,  /// internet control message protocol
    IGMP = IPPROTO_IGMP,  /// internet group management protocol
    GGP  = IPPROTO_GGP,   /// gateway to gateway protocol
    TCP  = IPPROTO_TCP,   /// transmission control protocol
    PUP  = IPPROTO_PUP,   /// PARC universal packet protocol
    UDP  = IPPROTO_UDP,   /// user datagram protocol
    IDP  = IPPROTO_IDP,   /// Xerox NS protocol
    IPV6 = IPPROTO_IPV6,  /// internet protocol version 6
}


/**
 * Hint option for resolving IP address
 */
enum AddressInfoFlags : int
{
    // Common options
    ANY,                       /// emulates the Posix behavior of null
    PASSIVE     = 0x00000001,  /// AI_PASSIVE     : gets address for bind() 
    CANONNAME   = 0x00000002,  /// AI_CANONNAME   : returns ai_canonname
    NUMERICHOST = 0x00000004,  /// AI_NUMERICHOST : prevent host-name resolution

    // std.c.windows.winsock doesn't define following options
    // NUMERICSERV = 0x00000008,  /// AI_NUMERICSERV : prevent service-name resolution
    // AI_ALL, AI_V4MAPPED, AI_ADDRCONFIG
}


class AddressException : Exception
{
    this(string msg)
    {
        super(msg);
    }
}


/**
 * AddressInfo is a class for resolving Address.
 */
class AddressInfo
{
    AddressInfoFlags flags;
    AddressFamily    family;
    SocketType       socketType;
    ProtocolType     protocolType;
    string           canonicalName;


  private:
    sockaddr_storage storage;  // for C API, mainly getnameinfo
    size_t           length;


  public:
    /**
     * for hint.
     */
    @safe
    this(AddressInfoFlags ai_flags = AddressInfoFlags.ANY, AddressFamily ai_family = AddressFamily.UNSPEC,
         SocketType ai_socktype = SocketType.ANY, ProtocolType ai_protocol = ProtocolType.ANY)
    {
        flags        = ai_flags;
        family       = ai_family;
        socketType   = ai_socktype;
        protocolType = ai_protocol;
    }


    /// ditto
    @safe
    this(AddressFamily ai_family, SocketType ai_socktype = SocketType.ANY,
         ProtocolType ai_protocol = ProtocolType.ANY, AddressInfoFlags ai_flags = AddressInfoFlags.ANY)
    {
        this(ai_flags, ai_family, ai_socktype, ai_protocol);
    }


    /// ditto
    @safe
    this(SocketType ai_socktype, ProtocolType ai_protocol = ProtocolType.ANY,
         AddressInfoFlags ai_flags = AddressInfoFlags.ANY, AddressFamily ai_family = AddressFamily.UNSPEC)
    {
        this(ai_flags, ai_family, ai_socktype, ai_protocol);
    }


    /// ditto
    @safe
    this(ProtocolType ai_protocol, AddressInfoFlags ai_flags = AddressInfoFlags.ANY,
         AddressFamily ai_family = AddressFamily.UNSPEC, SocketType ai_socktype = SocketType.ANY)
    {
        this(ai_flags, ai_family, ai_socktype, ai_protocol);
    }


    /**
     * called by static methods.
     */
    @trusted
    this(addrinfo* ai)
    in
    {
        assert(ai, "ai is null");
    }
    body
    {
        with (*ai) {
            family       = cast(AddressFamily)ai_family;
            socketType   = cast(SocketType)ai_socktype;
            protocolType = cast(ProtocolType)ai_protocol;
            length       = ai_addrlen;
            storage      = *cast(sockaddr_storage*)ai_addr;

            if (ai_canonname)
                canonicalName = to!string(ai_canonname);
        }
    }


    /**
     * Returns:
     *  the IP address associated with family.
     */
    @property @trusted
    IPAddress ipAddress() const
    {
        switch (family) {
        case AddressFamily.INET:
            return IPAddress(IPv4Address(ntohl((*cast(sockaddr_in*)&storage).sin_addr.s_addr)));
        case AddressFamily.INET6:
            return IPAddress(IPv6Address((*cast(sockaddr_in6*)&storage).sin6_addr.s6_addr,
                                         (*cast(sockaddr_in6*)&storage).sin6_scope_id));
        default:
            throw new AddressException(to!string(family) ~ " is not a IP address");
        }
    }


    /**
     * Returns:
     *  the port associated with family.
     */
    @property @trusted
    ushort port() const
    {
        switch (family) {
        case AddressFamily.INET:
            return ntohs((*cast(sockaddr_in*)&storage).sin_port);
        case AddressFamily.INET6:
            return ntohs((*cast(sockaddr_in6*)&storage).sin6_port);
        default:
            throw new AddressException(to!string(family) ~ " is not a IP address");
        }
    }


    /**
     * Returns:
     *  the local address associated with family.
     */
    @property @trusted
    LocalAddress localAddress() const
    {
        switch (family) {
        case AddressFamily.UNIX:
            return LocalAddress(to!string((*cast(sockaddr_un*)&storage).sun_path.ptr));
        default:
            throw new AddressException(to!string(family) ~ " is not a local address");
        }
    }


    /**
     * Returns:
     *  the path associated with family.
     */
    @property @trusted
    string path()
    {
        switch (family) {
        case AddressFamily.UNIX:
            return to!string((*cast(sockaddr_un*)&storage).sun_path.ptr);
        default:
            throw new AddressException(to!string(family) ~ " is not a local address");
        }
    }


    /**
     * Resolves address information.
     *
     * Returns:
     *  null if unable to resolve.
     */
    static AddressInfo[] getByNode(string node, string service = null, AddressInfo hint = null)
    in
    {
        assert(!(node is null && service is null));
    }
    body
    {
        /*
         * Supports AF_UNIX
         */
        AddressInfo createLocalAddress(AddressInfo info)
        in
        {
            assert(node, "UNIX family requires node");
        }
        body
        {
            auto sun  = sockaddr_un(cast(short)AddressFamily.UNIX);            
            auto addr = new AddressInfo(AddressFamily.UNIX, (info.socketType == SocketType.DGRAM)
                                        ? SocketType.DGRAM : SocketType.STREAM);

            sun.sun_path[0..node.length]     = node;
            sun.sun_path[node.length]        = '\0';
            addr.length                      = sockaddr_un.sizeof;
            *cast(sockaddr_un*)&addr.storage = sun;

            return addr;
        }

        enforce(getaddrinfo_func, "Your environment can't use getaddrinfo functions");

        addrinfo* res, hints;

        if (hint !is null) {
            // Local address support
            if (hint.family == AddressFamily.UNIX)
                return [createLocalAddress(hint)];

            hints = cast(addrinfo*)alloca(addrinfo.sizeof);

            memset(hints, 0, addrinfo.sizeof);

            with (*hints) {
                ai_flags    = cast(int)hint.flags;
                ai_family   = cast(int)hint.family;
                ai_socktype = cast(int)hint.socketType;
                ai_protocol = cast(int)hint.protocolType;
            }
        }

        if (getaddrinfo_func(node ? node.toStringz() : null, service ? service.toStringz() : null, hints, &res))
            return null;  // gai_strerror is better?

        AddressInfo[] addresses;

        for (auto p = res; p; p = p.ai_next)
            addresses ~= new AddressInfo(p);

        freeaddrinfo_func(res);

        return addresses;
    }


    /// ditto
    static AddressInfo[] getByService(string service, string node = null, AddressInfo hints = null)
    {
        return getByService(node, service, hints);
    }
}


unittest
{
    auto ais = AddressInfo.getByNode("localhost");
    assert(ais.length, "getaddrinfo failure");

    auto ai = AddressInfo.getByNode("/tmp/sock", null, new AddressInfo(AddressFamily.UNIX))[0];
    assert(ai);
    assert(ai.path       == "/tmp/sock");
    assert(ai.socketType == SocketType.STREAM);
}


/*
 * NI_* constants not found.
class NameInfo { }
 */


/**
 * IP address representation
 *
 * Currently, supports IP version 4 and 6.
 */
struct IPAddress
{
  private:
    enum Type { v4, v6 }

    union Impl
    {
        IPv4Address v4;
        IPv6Address v6;
    }

    Impl impl_;
    Type type_;


  public:
    /**
     * Constructs a IP address.
     *
     * Throws:
     *  AddressException if address format isn't IPv4 or IPv6.
     */
    @safe
    this(IPv4Address ipv4)
    {
        type_    = Type.v4;
        impl_.v4 = ipv4;
    }


    /// ditto
    @safe
    this(IPv6Address ipv6)
    {
        type_    = Type.v6;
        impl_.v6 = ipv6;
    }


    /// ditto
    @trusted
    this(ubyte[] addr)
    {
        if (addr.length == 4) {
            type_    = Type.v4;
            impl_.v4 = IPv4Address(addr);
        } else if (addr.length == 16) {
            type_    = Type.v6;
            impl_.v6 = IPv6Address(addr);
        } else {
            throw new AddressException("Unknown address format - " ~ to!string(addr));
        }
    }


    /// ditto
    @safe
    this(string addr)
    {
        if (IPv4Address.tryParse(addr, this))
            return;
        if (IPv6Address.tryParse(addr, this))
            return;

        throw new AddressException("Unknown address format - " ~ addr);
    }


    /**
     * Returns:
     *  the family of this address.
     */
    @property @safe
    nothrow AddressFamily family() const
    {
        return type_ == Type.v4 ? AddressFamily.INET : AddressFamily.INET6;
    }


    /**
     * Returns:
     *  true if this address is IP version 4.
     */
    @property @safe
    nothrow bool isIPv4() const
    {
        return type_ == Type.v4;
    }


    /**
     * Returns:
     *  true if this address is IP version 6.
     */
    @property @safe
    nothrow bool isIPv6() const
    {
        return type_ == Type.v6;
    }


    /**
     * Returns:
     *  the address as an IPv4Address.
     */
    @safe
    IPv4Address toIPv4()
    {
        if (!isIPv4)
            throw new AddressException("This IP address is not a version 4");

        return impl_.v4;
    }


    /**
     * Returns:
     *  the address as an IPv6Address.
     */
    @safe
    IPv6Address toIPv6()
    {
        if (!isIPv6)
            throw new AddressException("This IP address is not a version 6");

        return impl_.v6;
    }


    @safe
    bool opEquals(ref const IPAddress other) const
    {
        if (type_ != other.type_)
            return false;

        return type_ == Type.v4 ? impl_.v4 == other.impl_.v4 : impl_.v6 == other.impl_.v6;
    }


    @safe
    int opCmp(ref const IPAddress other) const
    {
        if (type_ < other.type_)
            return -1;
        else if (type_ > other.type_)
            return 1;
        else
            return type_ == Type.v4 ? impl_.v4 < other.impl_.v4 : impl_.v6 < other.impl_.v6;
    }


    @safe
    string toString() const
    {
        return type_ == Type.v4 ? impl_.v4.toString() : impl_.v6.toString();
    }
}


unittest
{
    ubyte[] addr = [1, 2, 3, 4];

    { // IP version 4
        auto ip = IPAddress(addr);
        assert(ip.isIPv4);
        assert(!ip.isIPv6);
        assert(ip.family   == AddressFamily.INET);
        assert(ip.toIPv4() == IPv4Address(addr));

        try {
            auto ipv6 = ip.toIPv6();
            assert(false);
        } catch (AddressException e) { }
    }

    addr = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0];

    { // IP version 6
        auto ip = IPAddress(addr);
        assert(!ip.isIPv4);
        assert(ip.isIPv6);
        assert(ip.family   == AddressFamily.INET6);
        assert(ip.toIPv6() == IPv6Address(addr));

        try {
            auto ipv4 = ip.toIPv4();
            assert(false);
        } catch (AddressException e) { }
    }
}


/**
 * IP version 4 representation for $(D IPAddress)
 *
 * Note:
 *  String-conversion is a environment-dependent function. You should not be 0-fill format.
 *
 * Example:
 * -----
 * auto v4 = IPv4Address("063.105.9.61");
 * writeln(v4);  // "63.105.9.61" on Mac, otherwise "51.105.9.61"
 * -----
 */
struct IPv4Address
{
  private:
    in_addr address_;


  public:
    /**
     * Tries to parse an IPv4 address string in the dotted-decimal form $(I a.b.c.d)
     * and returns the success and failure. Sets new object to $(D_PARAM ip) if succeeded.
     */
    @trusted
    static bool tryParse(string addr, ref IPAddress ip)
    {
        in_addr temp;

        if (inet_pton(AF_INET, addr.toStringz(), &temp) < 1) {
            return false;
        } else {
            ip = IPAddress(IPv4Address(ntohl(temp.s_addr)));
            return true;
        }
    }


    /**
     * Constructs a IPv4Address.
     *
     * Throws:
     *  AddressException if ddress format is not IP version 4.
     */
    @trusted
    this(ubyte[] bytes)
    in
    {
        assert(bytes.length == 4, "IP version 4 is 4 bytes");
    }
    body
    {
        address_.s_addr = *cast(typeof(address_.s_addr)*)bytes.ptr;
    }


    /// ditto
    @trusted
    this(uint addr)
    {
        address_.s_addr = htonl(addr);
    }


    /// ditto
    @trusted
    this(string addr)
    {
        enforceEx!(AddressException)(inet_pton(AF_INET, addr.toStringz(), &address_) > 0,
                                     "Unable to translate address '" ~ addr ~ "'");
    }


    /**
     * Returns:
     *  the address as an unsigned integer.
     *
     * Note:
     *  host byte order.
     */
    @trusted
    uint toUInt() const
    {
        return ntohl(address_.s_addr);
    }


    /**
     * Returns:
     *  the address as a byte representation.
     *
     * Note:
     *  network byte order.
     */
    @trusted
    ubyte[4] toBytes() const
    {
        import std.traits;

        ubyte[4] bytes;

        *cast(Unqual!(typeof(address_.s_addr))*)&bytes[0] = address_.s_addr;
        //*cast(typeof(address_.s_addr)*)bytes.ptr = address_.s_addr;

        return bytes;
    }


    @safe
    bool opEquals(ref const IPv4Address other) const
    {
        return address_.s_addr == other.address_.s_addr;
    }


    @safe
    int opCmp(ref const IPv4Address other) const
    {
        uint a = toUInt(), b = other.toUInt();

        if (a < b)
            return -1;
        else if (a == b)
            return 0;
        else
            return 1;
    }


    @trusted
    string toString() const
    {
        // enum ADDRSTRLEN = 16;  // avoid compilation error with INET_ADDRSTRLEN
        enum ADDRSTRLEN = INET_ADDRSTRLEN;  // avoid compilation error with INET_ADDRSTRLEN
        char[ADDRSTRLEN] buf;

        auto addr = inet_ntop(AF_INET, &address_, buf.ptr, ADDRSTRLEN);
        if (addr is null)
            return null;

        return to!string(addr);
    }
}


unittest
{
    // [1, 2, 3, 4] literal becomes string at initialization?
    auto v4 = IPv4Address(cast(ubyte[])[1, 2, 3, 4]);
    assert(v4.toBytes()  == [1, 2, 3, 4]);
    assert(v4.toString() == "1.2.3.4");

    v4 = IPv4Address("63.105.9.61");
    assert(v4.toBytes()  == [63, 105, 9, 61]);
    assert(v4.toString() == "63.105.9.61");
}


/**
 * IP version 6 representation for $(D IPAddress)
 *
 * Note:
 *  If your environment disables(or can't use) IP version 6, some methods fail or raise Exception.
 */
struct IPv6Address
{
  private:
    in6_addr address_;
    uint     scopeId_;


  public:
    /**
     * Tries to parse an IPv6 address string and returns the success and failure.
     * Sets new object to $(D_PARAM ip) if success.
     */
    @trusted
    static bool tryParse(string addr, ref IPAddress ip)
    {
        // In Linux, inet_pton can't parse scope-id.
        uint scopeId;
        auto i = addr.lastIndexOf('%', CaseSensitive.no);

        if (i >= 0) {
            scopeId = to!uint(addr[i + 1..$]);
            addr    = addr[0..i];
        }

        in6_addr temp;

        if (inet_pton(AF_INET6, addr.toStringz(), &temp) < 1) {
            return false;
        } else {
            ip = IPAddress(IPv6Address(temp.s6_addr, scopeId));
            return true;
        }
    }


    /**
     * Constructs a IPv6Address.
     *
     * Throws:
     *  AddressException if address format isn't IP version 6.
     */
    @safe
    this(ubyte[] bytes, uint id = 0)
    in
    {
        assert(bytes.length == 16, "IP version 6 is 16 bytes");
    }
    body
    {
        address_.s6_addr[] = bytes;
        scopeId_           = id;
    }


    /// ditto
    @trusted
    this(string addr)
    {
        // In Linux, inet_pton can't parse scope-id.
        auto i = addr.lastIndexOf('%', CaseSensitive.no);

        if (i >= 0) {
            scopeId_ = to!uint(addr[i + 1..$]);
            addr     = addr[0..i];
        }

        enforceEx!(AddressException)(inet_pton(AF_INET6, addr.toStringz(), &address_) > 0,
                                     "Unable to translate IPv6 address '" ~ addr ~ "'");
    }


    /**
     * Property for scope id.
     */
    @property @safe nothrow
    {
        uint scopeId() const
        {
            return scopeId_;
        }


        void scopeId(uint id)
        {
            scopeId_ = id;
        }
    }


    /**
     * Returns:
     *  the address as an unsigned integer.
     *
     * Throws:
     *  AddressException always.
     */
    @safe
    uint toUInt() const
    {
        throw new AddressException("uint type can't represents IPv6");
    }


    /**
     * Returns:
     *  the address as a byte representation.
     *
     * Note:
     *  network byte order.
     */
    @safe
    ubyte[16] toBytes() const
    {
        ubyte[16] bytes;

        bytes[] = address_.s6_addr[];

        return bytes;
    }


    @safe
    bool opEquals(ref const IPv6Address other) const
    {
        return (this < other) == 0;
    }


    @safe
    int opCmp(ref const IPv6Address other) const
    {
        auto a = address_.s6_addr, b = other.address_.s6_addr;

        if (a < b)
            return -1;
        else if (a > b)
            return 1;
        else
            return scopeId_ == other.scopeId_ ? 0 : scopeId_ < other.scopeId_ ? -1 : 1;
    }


    @trusted
    string toString() const
    {
        enum ADDRSTRLEN = 46;
        char[ADDRSTRLEN] buf;

        auto addr = inet_ntop(AF_INET6, &address_, buf.ptr, ADDRSTRLEN);
        if (addr is null)
            return null;

        auto result = to!string(addr);
        if (scopeId_)
            result ~= "%" ~ to!string(scopeId_);

        return result;
    }
}


unittest
{
    IPAddress ipa;

    if (IPv6Address.tryParse("::", ipa)) {
        auto addr = new ubyte[](16);
        auto v6 = IPv6Address(addr, 1);
        assert(v6.toString() == "::%1");

        v6 = IPv6Address("2001:0db8:0000:0000:1234:0000:0000:9abc");
        assert(v6.toString() == "2001:db8::1234:0:0:9abc");

        try {
            v6.toUInt();
            assert(false);
        } catch (Exception e) { }
    } else {
        writeln(" --- IPv6Address test: Your environment seems to be IP version 6 disable");
    }
}


/**
 * Local address representation
 */
struct LocalAddress
{
  private:
    string path_;


  public:
    /**
     * Constructs a LocalAddress with argument.
     */
    @safe
    this(string path)
    {
        path_ = path;
    }


    /**
     * Returns:
     *  the family of this address.
     */
    @property @safe
    AddressFamily family() const
    {
        return AddressFamily.UNIX;
    }


    /**
     * Returns:
     *  the path.
     */
    @property @safe
    string path() const
    {
        return path_;
    }


    @trusted
    bool opEquals(ref const LocalAddress other) const
    {
        return path_.cmp(other.path_) == 0;
    }


    @trusted
    int opCmp(ref const LocalAddress other) const
    {
        return path_.cmp(other.path_);
    }


    @safe
    string toString() const
    {
        return path;
    }
}


unittest
{
    auto ua1 = LocalAddress("path");
    assert(ua1.toString() == "path");

    auto ua2 = LocalAddress("root");
    assert(ua1 != ua2);
    assert(ua1 <= ua2);
}


/**
 * Detects whether T is a $(D Endpoint) type.
 *
 * Concept:
 * -----
 * Endpoint endpoint;             // can define a Endpoint object
 * auto name = endpoint.name;     // can return a pointer of sockaddr
 * auto size = endpoint.nameLen;  // can return a size of sockaddr_*
 * auto addr = endpoint.address;  // can return a corresponding Address object
 * -----
 */
template isEndpoint(Endpoint)
{
    enum isEndpoint = __traits(compiles,
        {
            Endpoint endpoint;             // can define a Endpoint object
            auto name = endpoint.name;     // can return a pointer of sockaddr
            auto size = endpoint.nameLen;  // can return a length of sockaddr_*
            auto addr = endpoint.address;  // can return a corresponding Address object
        });
}


/**
 * Endpoint representation for IP socket
 */
struct IPEndpoint
{
  private:
    extern(System) union SocketAddress
    {
        sockaddr     base;
        sockaddr_in  v4;
        sockaddr_in6 v6;
    }

    SocketAddress sa_;


  public:
    /**
     * Constructs a IPEndpoint.
     *
     * Initializes an address as IPv4 if the argument is port only.
     */
    @trusted
    this(IPAddress address, ushort portNumber)
    {
        if (address.isIPv4) {
            auto v4 = address.toIPv4();

            sa_.v4.sin_family      = AF_INET;
            sa_.v4.sin_port        = htons(portNumber);
            sa_.v4.sin_addr.s_addr = htonl(v4.toUInt());
        } else {
            auto v6 = address.toIPv6();

            sa_.v6.sin6_family         = AF_INET6;
            sa_.v6.sin6_port           = htons(portNumber);
            sa_.v6.sin6_addr.s6_addr[] = v6.toBytes();
            sa_.v6.sin6_scope_id       = v6.scopeId;
        }
    }


    /// ditto
    @trusted
    this(ushort portNumber)
    {
        sa_.v4.sin_family      = AF_INET;
        sa_.v4.sin_port        = htons(portNumber);
        sa_.v4.sin_addr.s_addr = INADDR_ANY;
    }


    /**
     * Endpoint constraint needs these methods.
     */
    @property @safe nothrow
    {
        sockaddr* name()
        {
            return &sa_.base;
        }


        const(sockaddr)* name() const
        {
            return &sa_.base;
        }


        int nameLen() const
        {
            return isIPv4 ? sa_.v4.sizeof : sa_.v6.sizeof;
        }
    }


    /**
     * Property for Address object associated with this endpoint.
     */
    @property @trusted
    {
        IPAddress address() const
        {
            IPAddress addr;

            if (isIPv4)
                addr = IPAddress(IPv4Address(ntohl(sa_.v4.sin_addr.s_addr)));
            else
                addr = IPAddress(IPv6Address(cast(ubyte[])sa_.v6.sin6_addr.s6_addr, sa_.v6.sin6_scope_id));

            return addr;
        }


        void address(IPAddress addr)
        {
            auto endpoint = IPEndpoint(addr, port);

            sa_ = endpoint.sa_;
        }
    }


    /**
     * Property for port associated with this endpoint.
     */
    @property @trusted
    {
        ushort port() const
        {
            return ntohs(isIPv4 ? sa_.v4.sin_port : sa_.v6.sin6_port);
        }


        void port(ushort portNumber)
        {
            (isIPv4 ? sa_.v4.sin_port : sa_.v6.sin6_port) = htons(portNumber);
        }
    }


    /**
     * Returns:
     *  the family of this endpoint.
     */
    @property @safe
    AddressFamily addressFamily() const
    {
        return isIPv4 ? AddressFamily.INET : AddressFamily.INET6;
    }


    @safe
    bool opEquals(ref const IPEndpoint other) const
    {
        return (this < other) == 0;
    }


    @safe
    int opCmp(ref const IPEndpoint other) const
    {
        auto lhs = address;
        auto rhs = other.address;

        if (lhs < rhs)
            return -1;
        else if (lhs > rhs)
            return 1;
        else
            return port == other.port ? 0 : port < other.port ? -1 : 1;
    }


    @trusted
    string toString() const
    {
        auto addr = address.toString();

        return (isIPv4 ? addr : "[" ~ addr ~ "]") ~ ":" ~ to!string(port);
    }


  private:
    @property @safe
    nothrow bool isIPv4() const
    {
        return sa_.base.sa_family == AF_INET;
    }
}


unittest
{
    auto endpoint = IPEndpoint(IPAddress("127.0.0.1"), 80);
    assert(endpoint.address.family == AddressFamily.INET);
    assert(endpoint.port           == 80);
    assert(endpoint.nameLen        == sockaddr_in.sizeof);
    assert(endpoint.address        == IPAddress("127.0.0.1"));
    assert(endpoint.toString()     == "127.0.0.1:80");

    endpoint.address = IPAddress("::%10");
    assert(endpoint.address.family == AddressFamily.INET6);
    assert(endpoint.nameLen        == sockaddr_in6.sizeof);
    assert(endpoint.toString()     == "[::%10]:80");
}


extern(System) private struct sockaddr_un
{
    short     sun_family;
    char[108] sun_path;
}


/**
 * Endpoint representation for UNIX socket
 */
struct LocalEndpoint
{
  private:
    extern(System) union SocketAddress
    {
        sockaddr    base;
        sockaddr_un unix;
    }

    SocketAddress sa_;


  public:
    /**
     * Constructs a LocalEndpoint.
     */
    @safe
    this(LocalAddress addr)
    in
    {
        assert(addr.path.length < sa_.unix.sun_path.sizeof, "path is too long.: " ~ addr.path);
    }
    body
    {
        sa_.unix.sun_family = AF_UNIX;
        sa_.unix.sun_path[0..addr.path.length] = addr.path;
        sa_.unix.sun_path[addr.path.length]    = '\0';
    }


    /**
     * Endpoint constraint needs these methods.
     */
    @property @safe nothrow
    {
        sockaddr* name()
        {
            return &sa_.base;
        }


        const(sockaddr)* name() const
        {
            return &sa_.base;
        }


        int nameLen() const
        {
            return sa_.unix.sizeof;
        }
    }


    /**
     * Property for Address object associated with this endpoint.
     */
    @property @trusted
    {
        LocalAddress address() const
        {
            return LocalAddress(to!string(sa_.unix.sun_path.ptr));
        }


        void address(LocalAddress addr)
        {
            auto endpoint = LocalEndpoint(addr);

            sa_ = endpoint.sa_;
        }
     }


    /**
     * Property for path associated with this endpoint.
     */
    @property @trusted
    {
        string path() const
        {
            return to!string(sa_.unix.sun_path.ptr);
        }


        void path(string sunPath)
        in
        {
            assert(sunPath.length < sa_.unix.sun_path.sizeof, "sunPath is too long.: " ~ sunPath);
        }
        body
        {
            sa_.unix.sun_path[0..sunPath.length] = sunPath;
            sa_.unix.sun_path[sunPath.length]    = '\0';
        }
    }


    /**
     * Returns:
     *  the family of this endpoint.
     */
    @property @safe
    AddressFamily addressFamily() const
    {
        return AddressFamily.UNIX;
    }


    @safe
    bool opEquals(ref const LocalEndpoint other) const
    {
        return (this < other) == 0;
    }


    @trusted
    int opCmp(ref const LocalEndpoint other) const
    {
        auto lhs = sa_.unix.sun_path[0..sa_.unix.sun_path.indexOf('\0')];
        auto rhs = other.sa_.unix.sun_path[0..other.sa_.unix.sun_path.indexOf('\0')];

        return lhs.cmp(rhs);
    }


    @trusted
    string toString() const
    {
        return cast(string)sa_.unix.sun_path[0..sa_.unix.sun_path.indexOf('\0')];
    }
}


unittest
{
    auto endpoint = LocalEndpoint(LocalAddress("path"));
    assert(endpoint.address.family == AddressFamily.UNIX);
    assert(endpoint.path           == "path");
    assert(endpoint.address        == LocalAddress("path"));

    endpoint.path = "root";
    assert(endpoint.path       == "root");
    assert(endpoint.nameLen    == sockaddr_un.sizeof);
    assert(endpoint.toString() == "root");
}


/**
 * Thrown on a Socket error.
 */
class SocketException : Exception
{
    int errorCode;  /// platform-specific error code


    /**
     * $(D_PARAM err) is converted to string using strerror_r.
     */
    this(string msg, int err = 0)
    {
        errorCode = err;

        version(Posix)
        {
            if (errorCode > 0) {
                char[80]     buf;
                const(char)* cs;

                version (linux)
                {
                    cs = strerror_r(errorCode, buf.ptr, buf.length);
                }
                else version (OSX)
                {
                    auto errs = strerror_r(errorCode, buf.ptr, buf.length);
                    if (errs == 0)
                        cs = buf.ptr;
                    else
                        cs = "Unknown error";
                }
                else version (FreeBSD)
                {
                    auto errs = strerror_r(errorCode, buf.ptr, buf.length);
                    if (errs == 0)
                        cs = buf.ptr;
                    else
                        cs = "Unknown error";
                }
                else
                {
                    static assert(false);
                }

                auto len = strlen(cs);

                if (cs[len - 1] == '\n')
                    len--;
                if (cs[len - 1] == '\r')
                    len--;

                msg = cast(string)(msg ~ ": " ~ cs[0 .. len]);
            }
        }

        super(msg);
    }
}


/**
 * for SocketOption.LINGER
 */
extern(System) struct Linger
{
    version(Windows)
    {
        ushort on;
        ushort time;
    }
    else
    {
        int on;
        int time;
    }
}


/**
 * How a socket is shutdown:
 */
enum SocketShutdown : int
{
    RECEIVE = SD_RECEIVE,  /// socket receives are disallowed
    SEND    = SD_SEND,     /// socket sends are disallowed
    BOTH    = SD_BOTH,     /// both RECEIVE and SEND
}

version (OSX)
{
    enum MSG_NOSIGNAL = 0x20000;
}

/**
 * Flags may be OR'ed together:
 */
enum SocketFlags : int
{
    NONE      = 0,              /// no flags specified
    OOB       = MSG_OOB,        /// out-of-band stream data
    PEEK      = MSG_PEEK,       /// peek at incoming data without removing it from the queue, only for receiving
    DONTROUTE = MSG_DONTROUTE,  /// data should not be subject to routing; this flag may be ignored. Only for sending
    NOSIGNAL  = MSG_NOSIGNAL,   /// don't send SIGPIPE signal on socket write error and instead return EPIPE
}


/**
 * The level at which a socket option is defined:
 */
enum SocketOptionLevel: int
{
    SOCKET = SOL_SOCKET,         /// socket level
    IP     = ProtocolType.IP,    /// internet protocol version 4 level
    ICMP   = ProtocolType.ICMP,  ///
    IGMP   = ProtocolType.IGMP,  ///
    GGP    = ProtocolType.GGP,   ///
    TCP    = ProtocolType.TCP,   /// transmission control protocol level
    PUP    = ProtocolType.PUP,   ///
    UDP    = ProtocolType.UDP,   /// user datagram protocol level
    IDP    = ProtocolType.IDP,   ///
    IPV6   = ProtocolType.IPV6,  /// internet protocol version 6 level
}


/**
 * Specifies a socket option:
 */
enum SocketOption: int
{
    DEBUG     = SO_DEBUG,      /// record debugging information
    BROADCAST = SO_BROADCAST,  /// allow transmission of broadcast messages
    REUSEADDR = SO_REUSEADDR,  /// allow local reuse of address
    LINGER    = SO_LINGER,     /// Linger on close if unsent data is present
    OOBINLINE = SO_OOBINLINE,  /// receive out-of-band data in band
    SNDBUF    = SO_SNDBUF,     /// send buffer size
    RCVBUF    = SO_RCVBUF,     /// receive buffer size
    DONTROUTE = SO_DONTROUTE,  /// do not route
    //TYPE      = SO_TYPE,       /// current socket type

    // SocketOptionLevel.TCP:
    TCP_NODELAY = .TCP_NODELAY,  /// disable the Nagle algorithm for send coalescing

    // SocketOptionLevel.IPV6:
    IPV6_UNICAST_HOPS   = .IPV6_UNICAST_HOPS,    ///
    IPV6_MULTICAST_IF   = .IPV6_MULTICAST_IF,    ///
    IPV6_MULTICAST_LOOP = .IPV6_MULTICAST_LOOP,  ///
    IPV6_JOIN_GROUP     = .IPV6_JOIN_GROUP,      ///
    IPV6_LEAVE_GROUP    = .IPV6_LEAVE_GROUP,     ///
}


/*
 * Need?
struct SocketOption {}
 */


/**
 * Socket is a class that creates a communication endpoint using the Berkeley sockets interface.
 *
 * Socket's method raises SocketException when internal operation returns error.
 * If you want to know error detail, please use errno.
 *
 * Example:
 * -----
 * alias Socket!IPEndpoint IPSocket;
 *
 * auto site  = "www.digitalmars.com";
 * auto hints = new AddressInfo(AddressInfoFlags.ANY, AddressFamily.INET,
 *                              SocketType.STREAM, ProtocolType.TCP);
 *
 * if (auto addrInfo = AddressInfo.getByNode(site, "http", hints)) {
 *     auto addr   = addrInfo[0];
 *     auto socket = new IPSocket(addr);
 *
 *     socket.connect(IPEndpoint(addr.ipAddress, addr.port));
 *     socket.send("GET / HTTP/1.0\r\nHOST: " ~ site ~ ":" ~ to!string(addr.port) ~"\r\n\r\n");
 *
 *     int n;
 *     char[] result, buffer = new char[](100);
 *
 *     while ((n = socket.receive(buffer)) > 0)
 *         result ~= buffer[0..n];
 *
 *     write(result);
 *
 *     socket.shutdown(SocketShutdown.BOTH);
 *     socket.close();
 * }
 * -----
 */
class Socket(Endpoint) if (isEndpoint!Endpoint)
{
  private:
    socket_t      handle_;
    AddressFamily family_;

    version(Windows) bool blocking_ = false;  // Property for get or set whether the socket is blocking or nonblocking.


  public:
    /**
     * Constructs a blocking socket. If a single protocol type exists to support
     * this socket type within the address family, the ProtocolType may be omitted.
     */
    this(AddressFamily af, SocketType type, ProtocolType protocol = ProtocolType.ANY)
    {
        handle_ = cast(socket_t).socket(af, type, protocol);
        if (handle_ == socket_t.init)
            throw new SocketException("Unable to create socket", lastError());
        family_ = af;
    }


    /// ditto
    this(AddressInfo addressInfo)
    in
    {
        assert(addressInfo, "AddressInfo must be initialized");
    }
    body
    {
        this(addressInfo.family, addressInfo.socketType, addressInfo.protocolType);
    }


    ~this()
    {
        if (handle_ != socket_t.init)
            closeSocket(handle_);
    }


    /**
     * Returns:
     *  underlying socket handle.
     */
    @property @safe
    nothrow socket_t handle() const
    {
        return handle_;
    }


    /**
     * Returns:
     *  the socket's address family.
     */
    @property @safe
    nothrow AddressFamily family() const
    {
        return family_;
    }


    /**
     * Properties for blocking flag.
     */
    @property
    {
        bool blocking() const
        {
            version(Windows)
            {
                return blocking_;
            }
            else version(BsdSockets)
            {
                return !(.fcntl(handle, F_GETFL, 0) & O_NONBLOCK);
            }
        }


        void blocking(bool byes)
        {
            version(Windows)
            {
                uint num = !byes;
                if (.ioctlsocket(handle_, FIONBIO, &num) == _SocketError)
                    goto err;

                blocking_ = byes;
            }
            else version(BsdSockets)
            {
                int x = .fcntl(handle_, F_GETFL, 0);
                if (x == -1)
                    goto err;

                if (byes)
                    x &= ~O_NONBLOCK;
                else
                    x |= O_NONBLOCK;

                if (.fcntl(handle_, F_SETFL, x) == -1)
                    goto err;
            }

            return;  // Success.

          err:
            throw new SocketException("Unable to set socket blocking", lastError());
        }
    }


    /**
     * Property that indicates if this is a valid, alive socket.
     */
    @property
    bool isAlive() const
    {
        int  type;
        auto typesize = cast(socklen_t)type.sizeof;

        return !.getsockopt(handle_, SOL_SOCKET, SO_TYPE, cast(char*)&type, &typesize);
    }


    /**
     * Returns:
     *  the remote endpoint of this socket.
     */
    @property
    Endpoint remoteEndpoint()
    {
        Endpoint  endpoint;
        socklen_t nameLen = cast(socklen_t)endpoint.nameLen;

        if (.getpeername(handle_, endpoint.name, &nameLen) == _SocketError)
            throw new SocketException("Unable to obtain remote socket address", lastError());

        // enforce(endpoint.address.family == family_, "Endpoint family is mismatched");

        return endpoint;
    }


    /**
     * Returns: 
     *  the local endpoint of this socket.
     */
    @property
    Endpoint localEndpoint()
    {
        Endpoint  endpoint;
        socklen_t nameLen = cast(socklen_t)endpoint.nameLen;

        if (.getsockname(handle_, endpoint.name, &nameLen) == _SocketError)
            throw new SocketException("Unable to obtain local socket address", lastError());

        // enforce(endpoint.address.family == family_, "Endpoint family is mismatched");

        return endpoint;
    }


    /**
     * Associates a local address with this socket.
     */
    void bind(ref const Endpoint addr)
    {
        version(Windows)  // std.c.windows.winsock(original bind apply const) must go!
            auto result = .bind(handle_, cast(sockaddr*)addr.name, addr.nameLen);
        else
            auto result = .bind(handle_, addr.name, addr.nameLen);

        if (result == _SocketError)
            throw new SocketException("Unable to bind socket", lastError());
    }


    /**
     * Establish a connection. If the socket is blocking, connect waits for
     * the connection to be made. If the socket is nonblocking, connect
     * returns immediately and the connection attempt is still in progress.
     */
    void connect(ref const Endpoint addr)
    {
        version(Windows)  // std.c.windows.winsock(original connect apply const) must go!
            auto result = .connect(handle_, cast(sockaddr*)addr.name, addr.nameLen);
        else
            auto result = .connect(handle_, addr.name, addr.nameLen);

        if (result == _SocketError) {
            int err = lastError();

            if (!blocking) {
                version(Windows)
                {
                    if (WSAEWOULDBLOCK == err)
                        return;
                }
                else version(Posix)
                {
                    if (EINPROGRESS == err)
                        return;
                }
                else
                {
                    static assert(false);
                }
            }

            throw new SocketException("Unable to connect socket", err);
        }
    }


    /**
     * Listens for an incoming connection. bind must be called before you can
     * listen. The backlog is a request of how many pending incoming
     * connections are queued until accept'ed.
     */
    void listen(int backlog)
    {
        if (.listen(handle_, backlog) == _SocketError)
            throw new SocketException("Unable to listen on socket", lastError());
    }


    /**
     * Accepts an incoming connection. If the socket is blocking, accept
     * waits for a connection request. Throws SocketException if unable
     * to accept. See accepting for use with derived classes.
     */
    Socket accept()
    {
        socket_t newsock = cast(socket_t).accept(handle_, null, null);
        if (newsock == socket_t.init)
            throw new SocketException("Unable to accept socket connection", lastError());

        auto newSocket = accepting();

        newSocket.handle_ = newsock;
        newSocket.family_ = family_;
        version(Windows) newSocket.blocking_ = blocking_;  //inherits blocking mode

        return newSocket;
    }


    /**
     * Disables send and/or receive.
     *
     * Note:
     *  On Mac OS X, sometimes shutdown function returns error despite the non-failure.
     *  I don't understand this behavior(Mac-specified bug?).
     */
    void shutdown(SocketShutdown how)
    {
        immutable result = .shutdown(handle_, cast(int)how);
        version (OSX) {} else
        {
            if (result == _SocketError)
                throw new SocketException("Unable to shutdown socket", lastError());
        }
    }


    /**
     * Immediately drop any connections and release socket resources.
     * Calling shutdown before close is recommended for connection-oriented
     * sockets. The Socket object is no longer usable after close.
     *
     * Note:
     *  Calling shutdown() before this is recommended for connection-oriented sockets
     */
    void close()
    {
        closeSocket(handle_);
        handle_ = socket_t.init;
    }


    /**
     * Sends data on the connection. If the socket is blocking and
     * there is no buffer space left, send waits.
     *
     * Returns:
     *   the number of bytes actually sent, or -1 on error.
     *
     * Note:
     *  This method assumes you connect()ed.
     */
    long send(const(void)[] buf, SocketFlags flags = SocketFlags.NONE)
    {
        flags |= SocketFlags.NOSIGNAL;

        version(Windows)
            immutable result = .send(handle_, buf.ptr, to!int(buf.length), cast(int)flags);
        else
            immutable result = .send(handle_, buf.ptr, buf.length, cast(int)flags);

        if (result == _SocketError)
            throw new SocketException("Unable to send data", lastError());

        return result;
    }


    /**
     * Send data to a specific destination Address. If the destination address is not specified,
     * a connection must have been made and that address is used. If the socket is blocking
     * and there is no buffer space left, sendTo waits.
     *
     * Note:
     *  This method assumes you connect()ed.
     */
    long sendTo(const(void)[] buf, ref const Endpoint to, SocketFlags flags = SocketFlags.NONE)
    {
        flags |= SocketFlags.NOSIGNAL;

        version(Windows)
            immutable result = .sendto(handle_, buf.ptr, to!int(buf.length), cast(int)flags, to.name, to.nameLen);
        else
            immutable result = .sendto(handle_, buf.ptr, buf.length, cast(int)flags, to.name, to.nameLen);

        if (result == _SocketError)
            throw new SocketException("Unable to send data", lastError());

        return result;
    }


    /// ditto
    ptrdiff_t sendTo(const(void)[] buf, SocketFlags flags = SocketFlags.NONE)
    {
        flags |= SocketFlags.NOSIGNAL;

        version(Windows)
            immutable result = .sendto(handle_, buf.ptr, to!int(buf.length), cast(int)flags, null, 0);
        else
            immutable result = .sendto(handle_, buf.ptr, buf.length, cast(int)flags, null, 0);

        if (result == _SocketError)
            throw new SocketException("Unable to send data", lastError());

        return result;
    }


    // int sendMessage()


    /**
     * Receives data on the connection. If the socket is blocking,
     * receive waits until there is data to be received.
     *
     * Returns:
     *  the number of bytes actually received, 0 on connection closure, or -1 on error.
     *
     * Note:
     *  This method assumes you connect()ed.
     */
    ptrdiff_t receive(void[] buf, SocketFlags flags = SocketFlags.NONE)
    {
        if (!buf.length) //return 0 and don't think the connection closed
            return 0;

        version(Windows)
            immutable result = .recv(handle_, buf.ptr, to!int(buf.length), cast(int)flags);
        else
            immutable result = .recv(handle_, buf.ptr, buf.length, cast(int)flags);

        // if (!result) //connection closed

        if (result == _SocketError)
            throw new SocketException("Unable to receive data", lastError());

        return result;
    }


    /**
     * Receives data and gets the remote endpoint Address. If the socket is blocking,
     * receiveFrom waits until there is data to be received.
     *
     * Returns:
     *  the number of bytes actually received, 0 if
     *  the remote side has closed the connection.
     *
     * Note:
     *  This method assumes you connect()ed.
     */
    ptrdiff_t receiveFrom(void[] buf, ref Endpoint from, SocketFlags flags = SocketFlags.NONE)
    {
        if (!buf.length)  //return 0 and don't think the connection closed
            return 0;

        auto nameLen = cast(socklen_t)from.nameLen;
        version(Windows)
            immutable result = .recvfrom(handle_, buf.ptr, to!int(buf.length), cast(int)flags, from.name, &nameLen);
        else
            immutable result = .recvfrom(handle_, buf.ptr, buf.length, cast(int)flags, from.name, &nameLen);

        // enforce(from.address.family == family_, "Endpoint family is mismatched");
        // if (!result) //connection closed

        if (result == _SocketError)
            throw new SocketException("Unable to receive data", lastError());

        return result;
    }


    /// ditto
    ptrdiff_t receiveFrom(void[] buf, SocketFlags flags = SocketFlags.NONE)
    {
        if (!buf.length)  // return 0 and don't think the connection closed
            return 0;

        version(Windows)
            immutable result = .recvfrom(handle_, buf.ptr, to!int(buf.length), cast(int)flags, null, null);
        else
            immutable result = .recvfrom(handle_, buf.ptr, buf.length, cast(int)flags, null, null);

        // if(!result) //connection closed
        if (result == _SocketError)
            throw new SocketException("Unable to receive data", lastError());

        return result;
    }


    // int receiveMessage()


    /**
     * Gets a socket option.
     */
    int getOption(SocketOptionLevel level, SocketOption option, void[] result)
    {
        auto len = cast(socklen_t)result.length;
        if (.getsockopt(handle_, cast(int)level, cast(int)option, result.ptr, &len) == _SocketError)
            throw new SocketException("Unable to get socket option", lastError());

        return len;
    }


    /**
     * Common case of getting integer and boolean options.
     */
    int getOption(SocketOptionLevel level, SocketOption option, out int result)
    {
        return getOption(level, option, (&result)[0 .. 1]);
    }


    /**
     * Gets the Linger option.
     */
    int getOption(SocketOptionLevel level, SocketOption option, out Linger result)
    {
        return getOption(level, option, (&result)[0 .. 1]);
    }


    //int getOption(SocketOptionLevel level, SocketOption option, out Duration result)


    /**
     * Sets a socket option.
     */
    void setOption(SocketOptionLevel level, SocketOption option, void[] value)
    {
        if (.setsockopt(handle_, cast(int)level, cast(int)option, cast(const)value.ptr, cast(uint)value.length) == _SocketError)
            throw new SocketException("Unable to set socket option", lastError());
    }


    /**
     * Common case for setting integer and boolean options.
     */
    void setOption(SocketOptionLevel level, SocketOption option, int value)
    {
        setOption(level, option, (&value)[0 .. 1]);
    }


    /**
     * Sets the Linger option.
     */
    void setOption(SocketOptionLevel level, SocketOption option, Linger value)
    {
        setOption(level, option, (&value)[0 .. 1]);
    }


    //void setOption(SocketOptionLevel level, SocketOption option, Duration timeout)


  protected:
    /**
     * Constructs a uninitialized Socket for accepting().
     */
    @safe
    this() { }


    /**
     * Called by accept when a new Socket must be created for a new
     * connection. To use a derived class, override this method and return an
     * instance of your class. The returned Socket's handle must not be set;
     * Socket has a protected constructor this() to use in this situation.
     *
     * Note:
     *  Override to use a derived class. The returned socket's handle must not be set.
     */
    @safe
    Socket accepting()
    out(result)
    {
        assert(result.handle == socket_t.init, "New socket's handle must not be set.");
    }
    body
    {
        return new Socket;
    }
}


private void closeSocket(socket_t handle)
{
    version(Windows)
    {
        auto result = .closesocket(handle);
    }
    else version(BsdSockets)
    {
        auto result = .close(handle);
    }

    if (result == _SocketError)
        throw new SocketException("Unable to close socket", lastError());
}


unittest
{
    { // version 4
        auto site  = "www.digitalmars.com";
        auto hints = new AddressInfo(AddressInfoFlags.ANY, AddressFamily.INET,
                                     SocketType.STREAM, ProtocolType.TCP);

        if (auto addrInfo = AddressInfo.getByNode(site, "http", hints)) {
            auto addr   = addrInfo[0];
            auto socket = new Socket!IPEndpoint(addr);

            socket.connect(IPEndpoint(addr.ipAddress, addr.port));
            socket.send("GET / HTTP/1.0\r\nHOST: " ~ site ~ ":" ~ to!string(addr.port) ~"\r\n\r\n");

            ptrdiff_t n;
            char[] result, buffer = new char[](100);

            while ((n = socket.receive(buffer)) > 0)
                result ~= buffer[0..n];

            assert(result.indexOf("HTTP/1.1 200 OK") == 0);

            try {
                socket.shutdown(SocketShutdown.BOTH);
            } catch (SocketException e) {
                // Probably Mac OS X
                writeln(" --- IPv4 Socket.shutdown: Why return error?");
            }
            socket.close();
        } else {
            writeln(" --- Socket IPv4 test: Socket unavailable! ---");
        }
    }
    { // version 6
        /* Please comment out if you enable IPv6.
        auto site  = "ipv6.goolge.com";
        auto hints = new AddressInfo(AddressInfoFlags.ANY, AddressFamily.INET6,
                                     SocketType.STREAM, ProtocolType.TCP);

        if (auto addrInfo = AddressInfo.getByNode(site, "http", hints)) {
            auto addr   = addrInfo[0];
            auto socket = new Socket!IPEndpoint(addr);

            socket.connect(IPEndpoint(addr.ipAddress, addr.port));
            socket.send("GET / HTTP/1.0\r\nHOST: " ~ site ~ ":" ~ to!string(addr.port) ~"\r\n\r\n");

            int n;
            char[] result, buffer = new char[](100);

            while ((n = socket.receive(buffer)) > 0)
                result ~= buffer[0..n];

            assert(result.indexOf("HTTP/1.1 200 OK") == 0);

            try {
                socket.shutdown(SocketShutdown.BOTH);
            } catch (SocketException e) {
                // Probably Mac OS X
                writeln(" --- IPv6 Socket.shutdown: Why return error?");
            }
            socket.close();
        } else {
            writeln(" --- Socket IPv6 test: Socket unavailable! ---");
        }
        */
    }
}
