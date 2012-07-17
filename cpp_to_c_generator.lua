
if #arg < 2 then
	print(string.format("Usage: %s %s <output name> <Input header files>", arg[-1], arg[0]))
	return
end
local output = arg[1]
local parse_file = arg[2]
local c_ns_prefix = ''

local pairs = pairs
local ipairs = ipairs
local tostring = tostring

local cindex = require"clang.cindex"
local cpp_parser = require"cpp_parser"

local parser = cpp_parser.new(true)

-- This will load all the symbols from "parse_file"
local args = {"-x", "c++", "-DNDEBUG", "-D_GNU_SOURCE", "-D__STDC_LIMIT_MACROS", "-D__STDC_CONSTANT_MACROS", "-D__STDC_FORMAT_MACROS"}
parser:parseTranslationUnit(parse_file, args, nil, cindex.CXTranslationUnit_SkipFunctionBodies)

local to_cpp_type = {
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
local function cpp_type(type, no_ns)
	if not type then return '' end
	local kind = type:getKind()
	local name
	if kind == 'Typedef' or kind == 'Record' then
		local cursor = type:getTypeDeclaration()
		if kind == 'Typedef' then
			local canon = type:getCanonical()
			kind = canon:getKind()
		end
		local node = parser:get_node(cursor)
		if node then
			name = node:get_name()
		else
			name = tostring(cursor)
		end
	elseif kind == 'Pointer' then
		name = cpp_type(type:getPointeeType(), no_ns) .. " *"
	elseif kind == 'LValueReference' then
		name = cpp_type(type:getPointeeType(), no_ns) .. " &"
	else
		local alt = to_cpp_type[kind]
		name = alt or kind
	end
	if type:isConstQualifiedType() then
		name = 'const ' .. name
	end
	return name, kind
end

local function c_type(type)
	if not type then return '' end
	local kind = type:getKind()
	local name
	if kind == 'Typedef' or kind == 'Record' then
		local cursor = type:getTypeDeclaration()
		if kind == 'Typedef' then
			local canon = type:getCanonical()
			kind = canon:getKind()
		end
		local node = parser:get_node(cursor)
		if node then
			name = c_ns_prefix .. node:get_cname()
		else
			name = tostring(cursor)
		end
	elseif kind == 'Pointer' then
		name = c_type(type:getPointeeType()) .. " *"
	elseif kind == 'LValueReference' then
		name = c_type(type:getPointeeType()) .. " *"
	else
		local alt = to_cpp_type[kind]
		name = alt or kind
	end
	if type:isConstQualifiedType() then
		name = 'const ' .. name
	end
	return name, kind
end

local typedefs = {}
local source = {}
local header = {}

local function append(tab, ...)
	local off = #tab
	for i=1,select('#', ...) do
		tab[off + i] = select(i, ...)
	end
	tab[#tab + 1] = '\n'
end

local function src(...)
	return append(source, ...)
end

local function head(...)
	return append(header, ...)
end

local function head_src(...)
	head(...)
	return src(...)
end

local function realize_c_type(type)
	if not type then return '' end
	local kind = type:getKind()
	if kind == 'Typedef' or kind == 'Record' then
		local cursor = type:getTypeDeclaration()
		local node = parser:get_node(cursor)
		local name
		if node then
			name = c_ns_prefix .. node:get_cname()
		else
			name = tostring(cursor)
		end
		if not typedefs[name] then
			local def = "typedef struct " .. name .. ' ' .. name .. ";"
			typedefs[name] = true
			typedefs[#typedefs + 1] = def
		end
	elseif kind == 'Pointer' then
		realize_c_type(type:getPointeeType())
	elseif kind == 'LValueReference' then
		realize_c_type(type:getPointeeType())
	end
end

local function need_wrap(type, to_c)
	local kind = type:getKind()
	local wrap
	-- convert between C++ references and C pointers.
	if kind == 'LValueReference' then
		if to_c then
			wrap = '&'
		else
			wrap = '*'
		end
	end
	return wrap
end

local function cast(type, value)
	return '((' .. type .. ')' .. value .. ')'
end

local function cpp_cast(type, value)
	realize_c_type(type)
	local c_ty = c_type(type)
	local cpp_ty = cpp_type(type)
	if c_ty ~= cpp_ty then
		cpp_ty = cpp_ty:gsub('&','*')
		return cast(cpp_ty, value)
	end
	return value
end

local function c_cast(type, value)
	realize_c_type(type)
	local c_ty = c_type(type)
	local cpp_ty = cpp_type(type)
	if c_ty ~= cpp_ty then
		return cast(c_ty, value)
	end
	return value
end

local function dump_wrapper_function(node, parent)
	local call = ''
	local wrap_call
	local kind = node.kind
	local cname = c_ns_prefix .. node:get_cname()
	local cpp_name = node:get_name(true)
	-- process return value.
	local ret_type = node.ret_type
	realize_c_type(ret_type)
	local ret, ret_kind = c_type(ret_type)
	if ret_kind == 'Record' then
		head_src("  /******** Can't wrap C++ function/method that returns a Class/Struct by-value *****/")
		return
	end
	local need_return = false
	if kind == 'Constructor' then
		ret_type = parent.type
		realize_c_type(ret_type)
		ret = c_type(ret_type) .. ' *'
	elseif ret ~= 'void' then
		need_return = true
		wrap_call = need_wrap(ret_type, true)
	end
	local cfunc_decl = ret .. " " .. cname .. "("
	-- process method calls
	if kind == 'CXXMethod' then
		call = "((" .. cpp_type(parent.type) .. " *)this_p)->" .. cpp_name .. '('
	elseif kind == 'Destructor' then
		call = "delete ((" .. cpp_type(parent.type) .. " *)this_p);\n"
	elseif kind == 'Constructor' then
		call = "return (" .. ret .. ")new " .. parent:get_name() .. "("
		need_return = false
	else
		call = cpp_name .. '('
	end
	-- process args.
	local args = node.args
	for i=1,#args do
		local arg = args[i]
		local name = arg.name
		local type = c_type(arg.type)
		if arg.is_this then
			type = type .. ' *'
		end
		if i > 1 then
			cfunc_decl = cfunc_decl .. ', '
			if call:sub(-1) ~= '(' then
				call = call .. ', '
			end
		end
		cfunc_decl = cfunc_decl .. type .. ' ' .. name
		if kind ~= 'Destructor' and not arg.is_this then
			name = cpp_cast(arg.type, name)
			local wrap = need_wrap(arg.type, false)
			if wrap then
				name = wrap .. '(' .. name .. ')'
			end
			call = call .. name
		end
	end
	if kind ~= 'Destructor' then
		call = call .. ')'
	end
	if wrap_call then
		call = wrap_call .. "(" .. call .. ')'
	end
	if need_return then
		-- cast to C type
		call = 'return ' .. c_cast(ret_type, call)
	end
	head("  " .. cfunc_decl .. ");")
	src("  " .. cfunc_decl .. ") {")
	src("    " .. call .. ";")
	src("  }")
end

local function dump_field(node, parent)
	if node.access ~= 'public' then return end
	head_src("  /* Field: " .. node.access .. ': ' ..
		cpp_type(node.type) .. " " .. node:get_name() .. " */")
end

local function dump_method(node, parent)
	if node.access ~= 'public' then return end
	head_src("  /* Method: " .. node.access .. ': ' .. node.name .. " */")
	dump_wrapper_function(node, parent)
end

local function dump_func(node)
	head_src("/* Function: " .. node.name .. " */")
	dump_wrapper_function(node, nil)
end

local function dump_fields_methods(node)
	if not node.has_definition then return end
	for name,field in pairs(node.fields) do
		dump_field(field, node)
	end
	for name,method in pairs(node.methods) do
		dump_method(method, node)
	end
end

local function dump_class(node)
	if node.access ~= 'public' then return end
	local name = node:get_name()
	if not node.has_definition then
		return
	end
	head_src("\n\n/* Class " .. name .. " { */")
	dump_fields_methods(node)
	head_src("/* }; */")
end

local function dump_struct(node)
	if node.access ~= 'public' then return end
	local name = node:get_name()
	if not node.has_definition then
		return
	end
	head_src("\n\n/* Struct " .. name .. " { */")
	dump_fields_methods(node)
	head_src("/* }; */")
end

for _,class in ipairs(parser.classes) do
	dump_class(class)
end
for _,struct in ipairs(parser.structs) do
	dump_struct(struct)
end
for _,func in ipairs(parser.functions) do
	dump_func(func)
end

local out_header = io.open(output .. ".h", "w")

out_header:write([[
/***************************************************************************************************
*************************** WARNING generated file. ************************************************
***************************************************************************************************/

]])

out_header:write([[
extern "C" {

]])
-- dump typedefs
for i=1,#typedefs do
	out_header:write(typedefs[i],'\n')
end

for i=1,#header do
	out_header:write(header[i])
end

out_header:write([[
} /* end extern "C" { */

]])

local out_src = io.open(output .. ".cpp", "w")

out_src:write([[
/***************************************************************************************************
*************************** WARNING generated file. ************************************************
***************************************************************************************************/

]])

out_src:write('#include "', parse_file, '"\n')

out_src:write([[
extern "C" {

]])

out_src:write('#include "', output, '.h"\n')

for i=1,#source do
	out_src:write(source[i])
end

out_src:write([[
} /* end extern "C" { */

]])

