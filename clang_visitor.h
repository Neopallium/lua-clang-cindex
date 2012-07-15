
typedef enum CXChildVisitResult (*lua_visitor)(CXCursor *cursor, CXCursor *parent, void *ud);

typedef struct {
	lua_visitor visitor;
	void *ud;
} HelperVisitorUD;

enum CXChildVisitResult clang_c_helper_visitor(CXCursor cursor, CXCursor parent, CXClientData ud);

