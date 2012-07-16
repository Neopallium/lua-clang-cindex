
local Index_h = "/usr/include/clang-c/Index.h"
local parse_file = arg[1] or Index_h


local ffi = require"ffi"

local clang = require"clang.cindex"

--
-- UnitVisitor
--
-- This will load all the symbols from 'IndexTest.pch'
local cnt = 0
local to_ctype = {
  -- Builtin types
	Void = 'void',
  Bool = 'bool',
  Char_U = 'Char_U',
  UChar = 'unsigned char',
  Char16 = 'Char16',
  Char32 = 'Char32',
  UShort = 'unsigned short',
  UInt = 'unsigned',
  ULong = 'unsigned long',
  ULongLong = 'unsigned long long',
  UInt128 = 'unsigned Int128',
  Char_S = 'char',
  SChar = 'SChar',
  WChar = 'WChar',
  Short = 'Short',
  Int = 'int',
  Long = 'long',
  LongLong = 'long long',
  Int128 = 'Int128',
  Float = 'float',
  Double = 'double',
  LongDouble = 'long double',
  NullPtr = 'NullPtr',
}
local function ctype(type)
	local kind = type:getKind()
	local name
	if kind == 'Typedef' or kind == 'Record' then
		local cursor = type:getTypeDeclaration()
		name = tostring(cursor)
	elseif kind == 'Pointer' then
		name = ctype(type:getPointeeType()) .. " *"
	elseif kind == 'LValueReference' then
		name = ctype(type:getPointeeType()) .. " &"
		--local cursor = type:getTypeDeclaration()
		--name = tostring(cursor)
	else
		local alt = to_ctype[kind]
		name = alt or kind
	end
	if type:isConstQualifiedType() then
		name = 'const ' .. name
	end
	return name
end

local function dump_func(cursor)
	-- create function decl
	local type = cursor:getType()
	local func_decl = ctype(type:getResultType()) .. ' ' .. cursor:getSpelling() .. "("
	local num_args = cursor:getNumArguments()
	for i=0,num_args-1 do
		local arg = cursor:getArgument(i)
		local name = arg:getSpelling()
		local atype = type:getArgType(i)
		if i > 0 then
			func_decl = func_decl .. ', '
		end
		func_decl = func_decl .. ctype(atype) .. ' ' .. name
	end
	func_decl = func_decl .. ')'
	if type:isConstQualifiedType() then
		func_decl = func_decl .. ' const'
	end

	local kind = cursor:getKind()
	local loc = cursor:getLocation()
	local file, line = loc:getSpelling()
	print("-- " .. kind .. ": " .. func_decl .. ";")
end

local function dump_method(cursor, parent)
	local kind = cursor:getKind()
	-- create method
	local type = cursor:getType()
	local func_decl = ''
	if kind == 'CXXMethod' then
		func_decl = func_decl .. ctype(type:getResultType()) .. ' '
	end
	func_decl = func_decl .. cursor:getSpelling() .. "("
	local num_args = cursor:getNumArguments()
	for i=0,num_args-1 do
		local arg = cursor:getArgument(i)
		local name = arg:getSpelling()
		local atype = type:getArgType(i)
		if i > 0 then
			func_decl = func_decl .. ', '
		end
		func_decl = func_decl .. ctype(atype) .. ' ' .. name
	end
	func_decl = func_decl .. ')'
	if type:isConstQualifiedType() then
		func_decl = func_decl .. ' const'
	end

	local loc = cursor:getLocation()
	local file, line = loc:getSpelling()
	print("-- " .. kind .. ": " .. func_decl .. ";")
end

local function dump_field(cursor, parent)
	local kind = cursor:getKind()
	local type = cursor:getType()
	print("-- " .. kind .. ": " .. ctype(type) .. " " .. cursor:getSpelling() .. ";")
end

local function dump_class(cursor)
	print("-- class " .. cursor:getSpelling() .. " {")
end

local function dump_struct(cursor)
	print("-- struct " .. cursor:getSpelling() .. " {")
end

local function dump_cursor(cursor, parent)
	local kind = cursor:getKind()
	local type = cursor:getType()
	local pkind = parent:getKind()
	if pkind == 'ClassDecl' or pkind == 'StructDecl' then
		if kind == "FieldDecl" then
			return dump_field(cursor, parent)
		elseif kind == "FunctionDecl" then
			return dump_method(cursor, parent)
		elseif type:getKind() == "FunctionProto" then
			return dump_method(cursor, parent)
		end
	elseif kind == "FunctionDecl" then
		return dump_func(cursor)
	elseif kind == "ClassDecl" then
		return dump_class(cursor)
	elseif kind == "StructDecl" then
		return dump_struct(cursor)
	elseif kind == "FieldDecl" then
		return dump_field(cursor)
	elseif type:getKind() == "FunctionProto" then
		return dump_func(cursor)
	else
		local loc = cursor:getLocation()
		local file, line = loc:getSpelling()
		--print("-- ", kind, cursor:getSpelling(), type, file, line)
	end
end

local function TranslationUnitVisitor(cursor, parent, client_data)
	local file = cursor:getFile()
	if file == nil then return clang.CXChildVisit_Recurse end
	if file:getName() ~= parse_file then
		--return clang.CXChildVisit_Continue
		return clang.CXChildVisit_Recurse
	end
	dump_cursor(cursor, parent)
	cnt = cnt + 1
	--return clang.CXChildVisit_Continue
	return clang.CXChildVisit_Recurse
end


-- Index
local Idx = clang.createIndex(1,1)
assert(Idx ~= nil, "Failed to create Idx")

-- This will load all the symbols from Index.h
local args = {"-x", "c++", "-DNDEBUG", "-D_GNU_SOURCE", "-D__STDC_LIMIT_MACROS", "-D__STDC_CONSTANT_MACROS", "-D__STDC_FORMAT_MACROS"}
local TU = Idx:parseTranslationUnit(parse_file, args, nil, clang.CXTranslationUnit_SkipFunctionBodies)
assert(TU ~= nil, "Failed to create TU")

print("TU range:", TU:getRange())
local tokens = TU:getTokens()
tokens:annotateTokens()
local last_comment = 0
for i=0,tokens:getNumTokens()-1 do
	local cursor = tokens:getTokenCursor(i)
	local ckind = cursor:getKind()
	local kind = tokens:getTokenKind(i)
	--print(i,"token:", tokens:getTokenKind(i), ckind, cursor)
	if kind == "Comment" then
		last_comment = i
	elseif kind == "Keyword" then
		if ckind == "FunctionDecl" then
			print(tokens:getTokenSpelling(last_comment))
			dump_func(cursor)
		end
	end
	--print(tokens:getTokenSpelling(i))
end

TU:visitChildren(TranslationUnitVisitor)
print("nodes = ", cnt)
cnt = 0

