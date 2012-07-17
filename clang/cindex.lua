
local ffi = require"ffi"

local Index_h = "/usr/include/clang-c/Index.h"
local f = assert(io.open(Index_h,"r"))
local index_h = f:read("*a")
f:close()
-- Fix-ups
index_h = index_h:gsub("#include[^\n]*\n","\n")
index_h = index_h:gsub("#ifdef __cplusplus[^#]*#endif\n","\n")
index_h = index_h:gsub("#ifdef __has_feature.-#endif\n","\n")
index_h = index_h:gsub("CINDEX_LINKAGE","")
index_h = index_h:gsub("CINDEX_DEPRECATED","")
index_h = index_h:gsub("#define[^#\n]*\n","\n")

index_h = index_h:gsub("\n?#[^\n]*\n","\n\n")

ffi.cdef[[
typedef uint64_t time_t;

typedef struct CXFileImpl CXFileImpl;
typedef CXFileImpl *CXFile;
typedef struct CXIndexImpl CXIndexImpl;
typedef CXIndexImpl *CXIndex;
]]

--io.write(index_h)
ffi.cdef(index_h)
local C = ffi.load("/usr/lib/llvm/libclang.so")

-- process 'enum' types
local enums = {}
local E = {}
for name, values in index_h:gmatch("enum%s+([_%w]*)%s+(%b{})") do
	local enum = enums[name] or {}
	enums[name] = enum
	-- strip comments
	values = values:gsub("/%*.-%*/","")
	for name in values:gmatch("[\n{]%s*([%w_]+)%s*[=,}]") do
		local idx = name:find("_")
		local gname, sub_name = name:sub(1,idx-1), name:sub(idx+1)
		local group = E[gname] or {}
		E[gname] = group
		group[sub_name] = num

		local num = C[name]
		if not enum[num] then
			enum[num] = name
			group[num] = sub_name
		end
	end
end

--
-- Kind enums.
--

local K = {}
for ktype in pairs(enums) do
	local ktype = ktype:match("(%w-)Kind")
	if ktype then
		local kind = E[ktype]
		K[ktype] = kind
	end
end

-- Convert CXString to Lua String
local function CXString(CXStr)
	local str = ffi.string(C.clang_getCString(CXStr))
	C.clang_disposeString(CXStr)
	return str
end

--
-- Cursor Visitor wrapper.
--
ffi.cdef[[
typedef enum CXChildVisitResult (*lua_visitor)(CXCursor *cursor, CXCursor *parent, void *ud);

typedef struct {
	lua_visitor visitor;
	void *ud;
} HelperVisitorUD;

enum CXChildVisitResult clang_c_helper_visitor(CXCursor cursor, CXCursor parent, CXClientData ud);
]]
local helper_C = ffi.load("./clang_visitor.so")

local visitors = {}
local function createVisitor(func, lua_ud)
	local visitor_ud = ffi.new("HelperVisitorUD", function(cursor, parent, ud)
		return func(cursor[0], parent[0], lua_ud)
	end, ud)
	visitors[func] = visitor_ud
	return helper_C.clang_c_helper_visitor, visitor_ud
end


-- CXSourceLocation
local SourceLocation = {}
local line_tmp, column_tmp, offset_tmp =
	ffi.new("unsigned[1]"), ffi.new("unsigned[1]"), ffi.new("unsigned[1]")
local function getLocation(self, cfunc)
	local file = ffi.new("CXFile[1]")
	cfunc(self, file, line_tmp, column_tmp, offset_tmp)
	return file[0], line_tmp[0], column_tmp[0], offset_tmp[0]
end
function SourceLocation:getExpansion()
	return getLocation(self, C.clang_getExpansionLocation)
end
function SourceLocation:getPresumed()
	return getLocation(self, C.clang_getPresumedLocation)
end
function SourceLocation:getInstantiation()
	return getLocation(self, C.clang_getInstantiationLocation)
end
function SourceLocation:getSpelling()
	return getLocation(self, C.clang_getSpellingLocation)
end
ffi.metatype("CXSourceLocation", { __index = SourceLocation,
__tostring = function(self)
	local file, line, column, offset = self:getSpelling()
	return tostring(file) .. ":" .. tostring(line)
end})

-- CXSourceRange
local SourceRange = {}
function SourceRange:getStart()
	return C.clang_getRangeStart(self)
end
function SourceRange:getEnd()
	return C.clang_getRangeEnd(self)
end
ffi.metatype("CXSourceRange", { __index = SourceRange,
__tostring = function(self)
	return tostring(self:getStart()) .. ' <-> ' .. tostring(self:getEnd())
end})

-- CXFile
local File = {}
function File:getName()
	--if self == nil then return nil end
	return CXString(C.clang_getFileName(self))
end
function File:getTime()
	if self == nil then return 0 end
	return tonumber(C.clang_getFileTime(self))
end
ffi.metatype("CXFileImpl", { __index = File,
__tostring = function(self)
	if self == nil then return 'nil' end
	return self:getName()
end
})

-- CXType
local Type = {}
function Type:getKind()
	return K.CXType[self.kind]
end
function Type:getCanonical()
	return C.clang_getCanonicalType(self)
end
function Type:isConstQualifiedType()
	return C.clang_isConstQualifiedType(self) == 1
end
function Type:isVolatileQualifiedType()
	return C.clang_isVolatileQualifiedType(self) == 1
end
function Type:isRestrictQualifiedType()
	return C.clang_isRestrictQualifiedType(self) == 1
end
function Type:getTypeDeclaration()
	return C.clang_getTypeDeclaration(self)
end
function Type:getPointeeType()
	return C.clang_getPointeeType(self)
end
function Type:getResultType()
	return C.clang_getResultType(self)
end
function Type:getCursorResultType()
	return C.clang_getCursorResultType(self)
end
function Type:getNumArgTypes()
	return C.clang_getNumArgTypes(self)
end
function Type:getArgType(idx)
	return C.clang_getArgType(self, idx)
end
function Type:isFunctionTypeVariadic()
	return C.clang_isFunctionTypeVariadic(self)
end
function Type:isPODType()
	return (C.clang_isPODType(self) == 1)
end
function Type:getElementType()
	return C.clang_getElementType(self)
end
function Type:getNumElements()
	return C.clang_getNumElements(self)
end
function Type:getArrayElementType()
	return C.clang_getArrayElementType(self)
end
ffi.metatype("CXType", { __index = Type,
__tostring = function(self) return K.CXType[self.kind] end,
__eq = function(t1,t2)
	return (C.clang_equalTypes(t1, t2) == 1)
end})

-- CXCursor
local Cursor = {}
function Cursor:hash()
	return C.clang_hashCursor(self)
end
function Cursor:getKind()
	return K.CXCursor[self.kind]
end
function Cursor:getType()
	return C.clang_getCursorType(self)
end
function Cursor:getTypedefDeclUnderlyingType()
	return C.clang_getTypedefDeclUnderlyingType(self)
end
function Cursor:getEnumDeclIntegerType()
	return C.clang_getEnumDeclIntegerType(self)
end
function Cursor:getEnumConstantDeclValue()
	return C.clang_getEnumConstantDeclValue(self)
end
function Cursor:getEnumConstantDeclUnsignedValue()
	return C.clang_getEnumConstantDeclUnsignedValue(self)
end
function Cursor:getNumArguments()
	return C.clang_Cursor_getNumArguments(self)
end
function Cursor:getArgument(idx)
	return C.clang_Cursor_getArgument(self, idx)
end
function Cursor:getLanguage()
	return K.CXLanguage[C.clang_getCursorLanguage(self)]
end
function Cursor:getAvailability()
	return K.CXAvailability[C.clang_getCursorAvailability(self)]
end
function Cursor:getSpelling()
	return CXString(C.clang_getCursorSpelling(self))
end
function Cursor:getDisplayName()
	return CXString(C.clang_getCursorDisplayName(self))
end
function Cursor:getLocation()
	return C.clang_getCursorLocation(self)
end
function Cursor:getExtent()
	return C.clang_getCursorExtent(self)
end
function Cursor:getFile()
	local loc = self:getLocation()
	return loc:getSpelling()
end
function Cursor:getReferenced()
	return C.clang_getCursorReferenced(self)
end
function Cursor:getCanonical()
	return C.clang_getCanonicalCursor(self)
end
function Cursor:getDefinition()
	return C.clang_getCursorDefinition(self)
end
function Cursor:getSemanticParent()
	return C.clang_getCursorSemanticParent(self)
end
function Cursor:getLexicalParent()
	return C.clang_getCursorLexicalParent(self)
end
function Cursor:isDefinition()
	return (C.clang_isCursorDefinition(self) == 1)
end
function Cursor:getUSR()
	return CXString(C.clang_getCursorUSR(self))
end
function Cursor:isVirtualBase()
	return C.clang_isVirtualBase(self)
end
function Cursor:getCXXAccessSpecifier()
	return E.CX[C.clang_getCXXAccessSpecifier(self)]
end
function Cursor:visitChildren(visitor, ud)
	local cb, cb_ud = createVisitor(visitor, ud)
	return C.clang_visitChildren(self, cb, cb_ud)
end
ffi.metatype("CXCursor", { __index = Cursor,
__tostring = function(self) return self:getSpelling() end,
__eq = function(c1,c2)
	return (C.clang_equalCursors(c1, c2) == 1)
end})

--
-- Tokens
--
ffi.cdef[[

typedef struct CXTokens {
	CXTranslationUnit tu;
	CXToken *tokens;
	CXCursor *cursors;
	unsigned num_tokens;
} CXTokens;

void *calloc(size_t nmemb, size_t size);
void free(void *ptr);

]]

local Tokens = {}
function Tokens:getNumTokens()
	return self.num_tokens
end
function Tokens:getToken(idx)
	if idx < 0 or idx >= self.num_tokens then return nil end
	return self.tokens[idx]
end
function Tokens:getTokenCursor(idx)
	if idx < 0 or idx >= self.num_tokens then return nil end
	if self.cursors ~= nil then
		return self.cursors[idx]
	end
	return nil
end
function Tokens:getTokenKind(idx)
	if idx < 0 or idx >= self.num_tokens then return nil end
	return K.CXToken[C.clang_getTokenKind(self.tokens[idx])]
end
function Tokens:getTokenSpelling(idx)
	if idx < 0 or idx >= self.num_tokens then return nil end
	return CXString(C.clang_getTokenSpelling(self.tu, self.tokens[idx]))
end
function Tokens:getTokenLocation(idx)
	if idx < 0 or idx >= self.num_tokens then return nil end
	return C.clang_getTokenLocation(self.tu, self.tokens[idx])
end
function Tokens:getTokenExtent(idx)
	if idx < 0 or idx >= self.num_tokens then return nil end
	return C.clang_getTokenExtent(self.tu, self.tokens[idx])
end
function Tokens:annotateTokens()
	if self.cursors == nil then
		self.cursors = C.calloc(self.num_tokens, ffi.sizeof("CXCursor"))
	end
	C.clang_annotateTokens(self.tu, self.tokens, self.num_tokens, self.cursors)
end
ffi.metatype("CXTokens", { __index = Tokens,
__gc = function(self)
	if self.tokens then
		C.clang_disposeTokens(self.tu, self.tokens, self.num_tokens)
		self.tokens = nil
		self.num_tokens = 0
		if self.cursors ~= nil then
			C.free(self.cursors)
		end
	end
end})

local function CXTokens(tu, range)
	local self = ffi.new("CXTokens")
	local tokens = ffi.new("CXToken *[1]")
	local num_tokens = ffi.new("unsigned [1]")
	if not range then
		-- default to whole translation unit.
		range = tu:getRange()
	end
	C.clang_tokenize(tu, range, tokens, num_tokens)
	self.tu = tu
	self.tokens = tokens[0]
	self.num_tokens = num_tokens[0]
	self.cursors = nil
	return self
end

--
-- CXTranslationUnit
--
local TranslationUnit = {}
function TranslationUnit:getSpelling()
	return CXString(C.clang_getTranslationUnitSpelling(self))
end
function TranslationUnit:getRange()
	local cursor = C.clang_getTranslationUnitCursor(self)
	return cursor:getExtent()
end
function TranslationUnit:getCursor()
	return C.clang_getTranslationUnitCursor(self)
end
function TranslationUnit:getLocationCursor(loc)
	return C.clang_getCursor(self, loc)
end
function TranslationUnit:getTokens(range)
	return CXTokens(self, range)
end
function TranslationUnit:visitChildren(visitor, ud)
	local cursor = self:getCursor()
	return cursor:visitChildren(visitor, ud)
end
ffi.metatype("struct CXTranslationUnitImpl", { __index = TranslationUnit,
__tostring = function(self) return self:getSpelling() end})

local function new_TranslationUnit(tu)
	return ffi.gc(tu, C.clang_disposeTranslationUnit)
end

--
-- CXIndex
--
local Index = {}
function Index:getGlobalOptions()
	return C.clang_CXIndex_getGlobalOptions(self)
end
function Index:setGlobalOptions(opt)
	return C.clang_CXIndex_setGlobalOptions(self, opt)
end
function Index:createTranslationUnit(ast)
	return new_TranslationUnit(C.clang_createTranslationUnit(self, ast))
end
local function make_args(args)
	local num = #args
	if num == 0 then return nil, 0 end
	return ffi.new("const char *[?]", num, args), num
end
function Index:parseTranslationUnit(source, args, unsaved_files, options)
	local args, num = make_args(args)
	return new_TranslationUnit(C.clang_parseTranslationUnit(self, source, args, num, nil, 0, options))
end
function Index:createTranslationUnit(source, args, unsaved_files)
	local args, num = make_args(args)
	return new_TranslationUnit(C.clang_createTranslationUnit(self, source, num, args, 0, nil))
end
ffi.metatype("CXIndexImpl", { __index = Index,
__tostring = function(self) return self:getSpelling() end})


local _M = setmetatable({}, { __index = C })

function _M.createIndex(excludeDeclarationsFromPCH, displayDiagnostics)
	local Idx = C.clang_createIndex(excludeDeclarationsFromPCH, displayDiagnostics)
	return ffi.gc(Idx, C.clang_disposeIndex)
end

return _M

