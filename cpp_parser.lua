
local print = print
local assert = assert
local tostring = tostring

local cindex = require"clang.cindex"

local meths = {}
local parser_mt = { __index = meths }

local node_meths = {}
local node_mt = {
__index = node_meths,
}
local invalid_kinds = {
FirstInvalid = true,
InvalidFile = true,
NoDeclFound = true,
NotImplemented = true,
InvalidCode = true,
LastInvalid = true,
}

function node_meths:get_name(no_ns)
	if not no_ns and self.parent then
		return self:get_namespace() .. self.name
	end
	return self.name
end

function node_meths:get_cname()
	local kind = self.kind
	local name = self:get_name()
	if kind == 'Constructor' then
		name = self:get_namespace() .. 'new__' .. self.name
	elseif kind == 'Destructor' then
		name = self:get_namespace() .. 'delete__' .. self.name:gsub("^~", "")
	end
	name = name:gsub("::", "_")
	return name
end

function node_meths:get_namespace()
	local ns = self.ns
	if ns then return ns end
	if not self.parent then return '' end
	-- resolve namespace
	local pkind = self.parent.kind
	if pkind == 'TranslationUnit' then return '' end
	ns = self.parent:get_name()
	if ns ~= '' then
		ns = ns .. '::'
	end
	self.ns = ns
	return ns
end

function meths:get_node(cursor, parent)
	local id = cursor:getUSR()
	-- check for existing node
	local node = self.nodes[id]
	if node then
		return node, node.parent
	end

	local kind = cursor:getKind()
	-- find cursor's parent node
	if not parent and kind ~= "TranslationUnit" then
		parent = cursor:getSemanticParent()
		local pkind = parent:getKind()
		if invalid_kinds[pkind] then parent = nil end
	end
	if parent then
		parent = self:get_node(parent, nil)
	end

	-- new parent node.
	local node = setmetatable({
		id = id, parent = parent,
		-- node details
		kind = kind,
		type = cursor:getType(),
		name = cursor:getSpelling(),
		display_name = cursor:getDisplayName(),
		cursor = cursor,
	}, node_mt)
	self.nodes[id] = node
	return node, parent
end


function meths:parse_func_decl(node, cursor, parent)
	-- parse function/method/constructor/destructor
	local args = {}
	node.args = args
	local kind = node.kind
	local type = node.type
	-- return type
	local ret = type:getResultType()
	node.ret_type = ret
	if kind == 'CXXMethod' or kind == 'Destructor' then
		args[1] = { name = 'this_p', type = parent.type, is_this = true }
	end
	local num_args = cursor:getNumArguments()
	for i=0,num_args-1 do
		local arg = cursor:getArgument(i)
		local name = arg:getSpelling()
		local atype = type:getArgType(i)
		if name == '' then
			name = 'arg_' .. tostring(i)
		end
		args[#args+1] = { name = name, type = atype }
	end
end

function meths:parse_func(cursor, parent)
	local node = self:get_node(cursor, parent)
	self.functions[#self.functions + 1] = node
	return self:parse_func_decl(node, cursor, parent)
end

function meths:parse_method(cursor, parent)
	local node, parent = self:get_node(cursor, parent)
	if not parent then return end

	node.access = parent.cur_access
	local methods = parent.methods or {}
	methods[node.name] = node

	return self:parse_func_decl(node, cursor, parent)
end

function meths:parse_field(cursor, parent)
	local node, parent = self:get_node(cursor, parent)
	if not parent then return end
	node.access = parent.cur_access
	local fields = parent.fields or {}
	fields[node.name] = node
end

function meths:parse_class(cursor, parent)
	local node, parent = self:get_node(cursor, parent)
	if not node.idx then
		local idx = #self.classes + 1
		self.classes[idx] = node
		node.idx = idx
	end
	if not cursor:isDefinition() then return end
	node.has_definition = true
	node.access = 'public'
	local pkind = parent and parent.kind
	if pkind == 'ClassDecl' or pkind == 'StructDecl' then
		node.access = parent.cur_access
	end
	node.fields = {}
	node.methods = {}
	node.cur_access = 'private'
end

function meths:parse_struct(cursor, parent)
	local node, parent = self:get_node(cursor, parent)
	if not node.idx then
		local idx = #self.structs + 1
		self.structs[idx] = node
		node.idx = idx
	end
	if not cursor:isDefinition() then return end
	node.has_definition = true
	node.access = 'public'
	local pkind = parent and parent.kind
	if pkind == 'ClassDecl' or pkind == 'StructDecl' then
		node.access = parent.cur_access
	end
	node.fields = {}
	node.methods = {}
	node.cur_access = 'public'
end

local to_access = {
CXXPublic = "public",
CXXProtected = "protected",
CXXPrivate = "private",
}

function meths:parse_cursor(cursor, parent)
	local kind = cursor:getKind()
	local type = cursor:getType()
	if kind == "FieldDecl" then
		return self:parse_field(cursor, parent)
	elseif kind == "CXXMethod" or kind == 'Constructor' or kind == 'Destructor' then
		return self:parse_method(cursor, parent)
	elseif kind == "FunctionDecl" then
		return self:parse_method(cursor, parent)
	elseif kind == "CXXAccessSpecifier" then
		local parent = self:get_node(parent)
		local access = to_access[cursor:getCXXAccessSpecifier()]
		parent.cur_access = access
		return
	elseif kind == "FunctionDecl" then
		return self:parse_func(cursor, parent)
	elseif kind == "ClassDecl" then
		return self:parse_class(cursor, parent)
	elseif kind == "StructDecl" then
		return self:parse_struct(cursor, parent)
	end
end

local function TranslationUnitVisitor(cursor, parent, parser)
	-- skip cursors in included files.
	if parser.skip_includes then
		local file = cursor:getFile()
		if file == nil or file:getName() ~= parser.parse_file then
			return cindex.CXChildVisit_Continue
		end
	end
	parser:parse_cursor(cursor, parent)
	return cindex.CXChildVisit_Recurse
end

local _M = setmetatable({}, { __index = cindex })

function meths:parseTranslationUnit(parse_file, ...)
	self.parse_file = parse_file
	local TU = self.Idx:parseTranslationUnit(parse_file, ...)
	assert(TU ~= nil, "Failed to create TU")

	TU:visitChildren(TranslationUnitVisitor, self)
end

function _M.new(skip_includes)
	-- Index
	local Idx = cindex.createIndex(1,1)
	assert(Idx ~= nil, "Failed to create Idx")

	local self = setmetatable({
		Idx = Idx,
		skip_includes = skip_includes,
		nodes = {},
		functions = {},
		classes = {},
		structs = {}
	}, parser_mt)

	return self
end

return _M

