/**
	Templates and CTFE-functions useful for type introspection during  code generation.

	Some of those are very similar to `traits` utilities but instead of general type
	information focus on properties that are most important during such code generation.

	Copyright: © 2013 RejectedSoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig, Михаил Страшун
*/

module vson.meta.codegen;

import std.traits : FunctionTypeOf, isSomeFunction;

/*
	As user types defined inside unittest blocks don't have proper parent
	module, those need to be defined outside for tests that require module
	inspection for some reasons. All such tests use single declaration
	compiled in this module in unittest version.
*/
version(unittest)
{
	private:
		interface TestInterface
		{
			static struct Inner
			{
			}

			const(Inner[]) func1(ref string name);
			ref int func1();
			shared(Inner[4]) func2(...) const;
			immutable(int[string]) func3(in Inner anotherName) @safe;
		}
}

/**
	For a given type T finds all user-defined symbols it embeds.

	Important property of such symbols is that they are likely to
	need an explicit import if used in some other scope / module.

	Implementation is incomplete and tuned for REST interface generation needs.

	Params:
		T = type to introspect for qualified symbols

	Returns:
		tuple of "interesting" symbols, no duplicates
*/
template getSymbols(T)
{
	import std.typetuple : TypeTuple, NoDuplicates;
	import std.traits;

	private template Implementation(T)
	{
		static if (isAggregateType!T || is(T == enum)) {
			alias Implementation = TypeTuple!T;
		}
		else static if (isStaticArray!T || isArray!T) {
			alias Implementation = Implementation!(typeof(T.init[0]));
		}
		else static if (isAssociativeArray!T) {
			alias Implementation = TypeTuple!(
				Implementation!(ValueType!T),
				Implementation!(KeyType!T)
			);
		}
		else static if (isPointer!T) {
			alias Implementation = Implementation!(PointerTarget!T);
		}
		else
			alias Implementation = TypeTuple!();
	}

	alias getSymbols = NoDuplicates!(Implementation!T);
}

///
unittest
{
	import std.typetuple : TypeTuple;

	struct A {}
	interface B {}
	alias Type = A[const(B[A*])];

	// can't directly compare tuples thus comparing their string representation
	static assert (getSymbols!Type.stringof == TypeTuple!(A, B).stringof);
	static assert (getSymbols!int.stringof == TypeTuple!().stringof);
}

/**
	For a given interface I finds all modules that types in its methods
	come from.

	These modules need to be imported in the scope code generated from I
	is used to avoid errors with unresolved symbols for user types.

	Params:
		I = interface to inspect

	Returns:
		list of module name strings, no duplicates
*/
string[] getRequiredImports(I)()
	if (is(I == interface))
{
	import std.traits : MemberFunctionsTuple, moduleName,
		ParameterTypeTuple, ReturnType;

	if( !__ctfe )
		assert(false);

	bool[string] visited;
	string[] ret;

	void addModule(string name)
	{
		if (name !in visited) {
			ret ~= name;
			visited[name] = true;
		}
	}

	foreach (method; __traits(allMembers, I)) {
		foreach (overload; MemberFunctionsTuple!(I, method)) {
			alias FuncType = FunctionTypeOf!overload;

			foreach (symbol; getSymbols!(ReturnType!FuncType)) {
				static if (__traits(compiles, moduleName!symbol)) {
					addModule(moduleName!symbol);
				}
			}

			foreach (P; ParameterTypeTuple!FuncType) {
				foreach (symbol; getSymbols!P) {
					static if (__traits(compiles, moduleName!symbol)) {
						addModule(moduleName!symbol);
					}
				}
			}
		}
	}

	return ret;
}

///
unittest
{
	// `Test` is an interface using single user type
	enum imports = getRequiredImports!TestInterface;
	static assert (imports.length == 1);
	static assert (imports[0] == "vson.meta.codegen");
}

/**
 * Returns a Tuple of the parameters.
 * It can be used to declare function.
 */
template ParameterTuple(alias Func)
{
	static if (is(FunctionTypeOf!Func Params == __parameters)) {
		alias ParameterTuple = Params;
	} else static assert(0, "Argument to ParameterTuple must be a function");
}

///
unittest
{
	void foo(string val = "Test", int = 10);
	void bar(ParameterTuple!foo) { assert(val == "Test"); }
	// Variadic functions require special handling:
	import core.vararg;
	void foo2(string val, ...);
	void bar2(ParameterTuple!foo2, ...) { assert(val == "42"); }

	bar();
	bar2("42");

	// Note: outside of a parameter list, it's value is the type of the param.
	import std.traits : ParameterDefaultValueTuple;
	ParameterTuple!(foo)[0] test = ParameterDefaultValueTuple!(foo)[0];
	assert(test == "Test");
}

/// Returns a Tuple containing a 1-element parameter list, with an optional default value.
/// Can be used to concatenate a parameter to a parameter list, or to create one.
template ParameterTuple(T, string identifier, TUnused = void)
{
	import std.string : format;
	mixin(q{private void __func(T %s);}.format(identifier));
	alias ParameterTuple = ParameterTuple!__func;
}


/// Ditto
template ParameterTuple(T, string identifier, T DefVal)
{
	import std.string : format;
	mixin(q{private void __func(T %s = DefVal);}.format(identifier));
	alias ParameterTuple = ParameterTuple!__func;
}

///
unittest
{
	void foo(ParameterTuple!(int, "arg2")) { assert(arg2 == 42); }
	foo(42);

	void bar(string arg);
	void bar2(ParameterTuple!bar, ParameterTuple!(string, "val")) { assert(val == arg); }
	bar2("isokay", "isokay");

	// For convenience, you can directly pass the result of std.traits.ParameterDefaultValueTuple
	// without checking for void.
	import std.traits : PDVT = ParameterDefaultValueTuple;
	import std.traits : arity;
	void baz(string test, int = 10);

	static assert(is(PDVT!(baz)[0] == void));
	// void baz2(string test2, string test);
	void baz2(ParameterTuple!(string, "test2", PDVT!(baz)[0]), ParameterTuple!(baz)[0..$-1]) { assert(test == test2); }
	static assert(arity!baz2 == 2);
	baz2("Try", "Try");

	// void baz3(string test, int = 10, int ident = 10);
	void baz3(ParameterTuple!baz, ParameterTuple!(int, "ident", PDVT!(baz)[1])) { assert(ident == 10); }
	baz3("string");
}

/// Returns a string of the functions attributes, suitable to be mixed
/// on the LHS of the function declaration.
///
/// Unfortunately there is no "nice" syntax for declaring a function,
/// so we have to resort on string for functions attributes.
template FuncAttributes(alias Func)
{
	static if (__VERSION__ <= 2065)
	{
		import std.traits;
		enum FuncAttributes = {
			alias FA = FunctionAttribute;
			string res;
			enum attr = functionAttributes!Func;
			if (attr & FA.nothrow_) res ~= "nothrow ";
			if (attr & FA.property) res ~= "@property ";
			if (attr & FA.pure_) res ~= "pure ";
			if (attr & FA.ref_) res ~= "ref ";
			if (attr & FA.safe) res ~= "@safe ";
			if (attr & FA.trusted) res ~= "@trusted ";
			static if (is(FunctionTypeOf!Func == const)) res ~= "const ";
			static if (is(FunctionTypeOf!Func == immutable)) res ~= "immutable ";
			static if (is(FunctionTypeOf!Func == inout)) res ~= "inout ";
			static if (is(FunctionTypeOf!Func == shared)) res ~= "shared ";
			return res.length ? res[0 .. $-1] : res;
		}();
	}
	else
	{
		import std.array : join;
		enum FuncAttributes = [__traits(getFunctionAttributes, Func)].join(" ");
	}
}



/// A template mixin which allow you to clone a function, and specify the implementation.
mixin template CloneFunction(alias Func, string body_, string identifier = __traits(identifier, Func))
{
	// Template mixin: everything has to be self-contained.
	import std.string : format;
	import std.traits : ReturnType;
	import vson.meta.codegen : ParameterTuple, FuncAttributes;
	// Sadly this is not possible:
	// class Test {
	//   int foo(string par) pure @safe nothrow { /* ... */ }
	//   typeof(foo) bar {
	//      return foo(par);
	//   }
	// }
	mixin(q{
		ReturnType!Func %s(ParameterTuple!Func) %s {
			%s
		}
	}.format(identifier, FuncAttributes!Func, body_));
}

///
unittest
{
	interface ITest
	{
	  int foo(string par, int, string p = "foo", int = 10) pure @safe nothrow const;
	  @property int foo2() pure @safe nothrow const;
	}

	class Test : ITest
	{
		mixin CloneFunction!(ITest.foo, q{
			return 84;
		}, "customname");
	override:
		mixin CloneFunction!(ITest.foo, q{
			return 42;
		});
		mixin CloneFunction!(ITest.foo2, q{
			return 42;
		});
	}

	assert(new Test().foo("", 21) == 42);
	assert(new Test().foo2 == 42);
	assert(new Test().customname("", 21) == 84);
}
