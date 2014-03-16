/*
 * Copyright: 2014 by Digital Mars
 * License: $(LINK2 http://boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors: Walter Bright
 * 
 * From https://raw.github.com/WalterBright/phobos/scopebuffer/std/buffer/scopebuffer.d
 * http://forum.dlang.org/thread/ld2586$17f6$1@digitalmars.com
 */

module std.buffer.scopebuffer;


/**************************************
 * ScopeBuffer encapsulates using a local array as a temporary buffer.
 * It is initialized with the local array that should be large enough for
 * most uses. If the need exceeds the size, ScopeBuffer will resize it
 * using malloc() and friends.
 * ScopeBuffer cannot contain more than (uint.max-16)/2 elements.
 * ScopeBuffer is an OutputRange.
 * Example:
---
import core.stdc.stdio;
import std.buffer.scopebuffer;
void main()
{
    char[2] buf = void;
    auto textbuf = ScopeBuffer!char(buf);

    // Put characters and strings into textbuf, verify they got there
    textbuf.put('a');
    textbuf.put('x');
    textbuf.put("abc");
    assert(textbuf.length == 5);
    assert(textbuf[1..3] == "xa");
    assert(textbuf[3] == 'b');

    // Can shrink it
    textbuf.length = 3;
    assert(textbuf[0..textbuf.length] == "axa");
    assert(textbuf[textbuf.length - 1] == 'a');
    assert(textbuf[1..3] == "xa");

    textbuf.put('z');
    assert(textbuf[] == "axaz");

    // Can shrink it to 0 size, and reuse same memory
    textbuf.length = 0;
}
---
 * ScopeBuffer's contents are destroyed when ScopeBuffer goes out of scope.
 * Hence, copying the contents are necessary to keep them around:
---
import std.buffer.scopebuffer;
string cat(string s1, string s2)
{
    char[10] tmpbuf = void;
    auto textbuf = ScopeBuffer!char(tmpbuf);
    textbuf.put(s1);
    textbuf.put(s2);
    textbuf.put("even more");
    return textbuf[].idup;
}
---
 */

//debug=ScopeBuffer;

private import std.traits;

struct ScopeBuffer(T) if (isAssignable!T &&
                          !hasElaborateDestructor!T &&
                          !hasElaborateCopyConstructor!T &&
                          !hasElaborateAssign!T)
{
	import core.stdc.stdlib : malloc, realloc, free;
	import core.stdc.string : memcpy;
	//import std.stdio;
	
	/**************************
     * Initialize with buf to use as scratch buffer space.
     * Params:
     *  buf     Scratch buffer space, must have length that is even
     * Example:
     * ---
     * ubyte[10] tmpbuf = void;
     * auto sbuf = ScopeBuffer!ubyte(tmpbuf);
     * ---
     */
	this(T[] buf)
		in
	{
		assert(!(buf.length & resized));    // assure even length of scratch buffer space
		assert(buf.length <= uint.max);     // because we cast to uint later
	}
	body
	{
		this.buf = buf.ptr;
		this.bufLen = cast(uint)buf.length;
	}
	
	unittest
	{
		ubyte[10] tmpbuf = void;
		auto sbuf = ScopeBuffer!ubyte(tmpbuf);
	}
	
	/**************************
     * Destructor releases any memory used.
     * This will invalidate any references returned by the [] operator.
     */
	~this()
	{
		debug(ScopeBuffer) buf[0 .. bufLen] = 0;
		if (bufLen & resized)
			free(buf);
		buf = null;
		bufLen = 0;
		i = 0;
	}
	
	/****************************
     * Copying of ScopeBuffer is not allowed.
     */
	@disable this(this);
	
	/************************
     * Append element c to the buffer.
     */
	void put(T c)
	{
		/* j will get enregistered, while i will not because resize() may change i
         */
		const j = i;
		if (j == bufLen)
		{
			assert(j <= (uint.max - 16) / 2);
			resize(j * 2 + 16);
		}
		buf[j] = c;
		i = j + 1;
	}
	
	/************************
     * Append array s to the buffer.
     */
	void put(const(T)[] s)
	{
		const newlen = i + s.length;
		assert((cast(ulong)i + s.length) <= uint.max);
		const len = bufLen;
		if (newlen > len)
		{
			assert(len <= uint.max / 2);
			resize(newlen <= len * 2 ? len * 2 : newlen);
		}
		buf[i .. newlen] = s[];
		i = cast(uint)newlen;
	}
	
	/******
     * Retrieve a slice into the result.
     * Returns:
     *  A slice into the temporary buffer that is only
     *  valid until the next put() or ScopeBuffer goes out of scope.
     */
	@system T[] opSlice(size_t lower, size_t upper)
	in
	{
		assert(lower <= bufLen);
		assert(upper <= bufLen);
		assert(lower <= upper);
	}
	body
	{
		return buf[lower .. upper];
	}
	
	/// ditto
	@system inout(T[]) opSlice() inout
	{
		assert(i <= bufLen);
		return buf[0 .. i];
	}
	
	/*******
     * Retrieve the element at index i.
     */
	T opIndex(size_t i)
	{
		assert(i < bufLen);
		return buf[i];
	}
	
	/***
     * Returns:
     *  the number of elements in the ScopeBuffer
     */
	@property size_t length()
	{
		return i;
	}
	
	/***
     * Used to shrink the length of the buffer,
     * typically to 0 so the buffer can be reused.
     * Cannot be used to extend the length of the buffer.
     */
	@property void length(size_t i)
	in
	{
		assert(i <= this.i);
	}
	body
	{
		this.i = cast(uint)i;
	}
	
	alias opDollar = length;
	
private:
	T* buf;
	// Using uint instead of size_t so the struct fits in 2 registers in 64 bit code
	uint bufLen;
	enum resized = 1;         // this bit is set in bufLen if we control the memory
	uint i;
	
	void resize(size_t newsize)
		in
	{
		assert(newsize <= uint.max);
	}
	body
	{
		//writefln("%s: oldsize %s newsize %s", id, buf.length, newsize);
		void* newBuf;
		newsize |= resized;
		if (bufLen & resized)
		{
			/* Prefer realloc when possible
             */
			newBuf = realloc(buf, newsize * T.sizeof);
			if (!newBuf)
				assert(0);      // check stays even in -release mode
		}
		else
		{
			newBuf = malloc(newsize * T.sizeof);
			if (!newBuf)
				assert(0);
			memcpy(newBuf, buf, i * T.sizeof);
			debug(ScopeBuffer) buf[0 .. bufLen] = 0;
		}
		buf = cast(T*)newBuf;
		bufLen = cast(uint)newsize;
		
		/* This function is called only rarely,
         * inlining results in poorer register allocation.
         */
		version (DigitalMars)
			/* With dmd, a fake loop will prevent inlining.
             * Using a hack until a language enhancement is implemented.
             */
		while (1) { break; }
	}
}

unittest
{
	import core.stdc.stdio;
	import std.range;
	
	char[2] tmpbuf = void;
	{
		// Exercise all the lines of code except for assert(0)'s
		auto textbuf = ScopeBuffer!char(tmpbuf);
		
		static assert(isOutputRange!(ScopeBuffer!char, char));
		
		textbuf.put('a');
		textbuf.put('x');
		textbuf.put("abc");         // tickle put([])'s resize
		assert(textbuf.length == 5);
		assert(textbuf[1..3] == "xa");
		assert(textbuf[3] == 'b');
		
		textbuf.length = textbuf.length - 1;
		assert(textbuf[0..textbuf.length] == "axab");
		
		textbuf.length = 3;
		assert(textbuf[0..textbuf.length] == "axa");
		assert(textbuf[textbuf.length - 1] == 'a');
		assert(textbuf[1..3] == "xa");
		
		textbuf.put(cast(dchar)'z');
		assert(textbuf[] == "axaz");
		
		textbuf.length = 0;                 // reset for reuse
		assert(textbuf.length == 0);
		
		foreach (char c; "asdf;lasdlfaklsdjfalksdjfa;lksdjflkajsfdasdfkja;sdlfj")
		{
			textbuf.put(c); // tickle put(c)'s resize
		}
		assert(textbuf[] == "asdf;lasdlfaklsdjfalksdjfa;lksdjflkajsfdasdfkja;sdlfj");
	} // run destructor on textbuf here
	
}

unittest
{
	string cat(string s1, string s2)
	{
		char[10] tmpbuf = void;
		auto textbuf = ScopeBuffer!char(tmpbuf);
		textbuf.put(s1);
		textbuf.put(s2);
		textbuf.put("even more");
		return textbuf[].idup;
	}
	
	auto s = cat("hello", "betty");
	assert(s == "hellobettyeven more");
}

/*********************************
 * This is a slightly simpler way to create a ScopeBuffer instance
 * that uses type deduction.
 * Params:
 *      tmpbuf  the initial buffer to use
 * Returns:
 *      an instance of ScopeBuffer
 * Example:
---
ubyte[10] tmpbuf = void;
auto sb = scopeBuffer(tmpbuf);
---
 */

auto scopeBuffer(T)(T[] tmpbuf)
{
	return ScopeBuffer!T(tmpbuf);
}

unittest
{
	ubyte[10] tmpbuf = void;
	auto sb = scopeBuffer(tmpbuf);
}
