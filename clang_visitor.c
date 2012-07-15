
#include "clang-c/Index.h"

#include "clang_visitor.h"

enum CXChildVisitResult clang_c_helper_visitor(CXCursor cursor, CXCursor parent, CXClientData ud) {
	HelperVisitorUD *callback = ud;
	return callback->visitor(&cursor, &parent, callback->ud);
}

