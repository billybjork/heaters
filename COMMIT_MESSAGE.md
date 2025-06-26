feat: Implement functional domain modeling with "I/O at the edges" architecture

## Major Refactor Summary

This commit implements a comprehensive functional domain modeling refactor following "Domain Modeling Made Functional" principles, combined with Option C reorganization for consistent folder structure.

### 🎯 Architecture Transformation

**From**: Mixed I/O + business logic in single modules
**To**: Clean "I/O at the edges" functional architecture

- **Pure Domain Layer**: Business logic as pure functions (no I/O dependencies)
- **Infrastructure Layer**: Clean I/O adapters with consistent interfaces  
- **Orchestration Layer**: I/O coordination using domain + infrastructure

### 📁 Option C Reorganization

**Consistent Structure Achieved**:
```
lib/heaters/clips/
├── operations.ex + operations/     # Renamed from transform.ex
├── embedding.ex + embedding/       # Renamed from embed.ex
├── operations/shared/              # Consolidated shared utilities
└── operations/{sprite,keyframe,split,merge}/ # Co-located domain logic
```

**Benefits**:
- ✅ Consistent `operation.ex` + `operation/` pattern throughout
- ✅ No redundant directories (consolidated shared/)
- ✅ Clear separation: I/O orchestration (.ex) + pure domain logic (subdirs)
- ✅ Co-located domain logic with related operations

### 🔧 Implementation Details

**Namespace Updates**:
- `Heaters.Clips.Transform` → `Heaters.Clips.Operations`
- `Heaters.Clips.Embed` → `Heaters.Clips.Embedding`
- All domain modules moved to `Operations.{Operation}.{Module}`
- All shared utilities consolidated under `Operations.Shared`

**Files Restructured**: 17 domain modules + 4 operation modules + shared utilities
**References Updated**: 50+ files across contexts, workers, web layer, and tests

### 🧪 Quality Assurance

**Zero Breaking Changes**:
- ✅ All existing APIs preserved
- ✅ All workers continue functioning unchanged
- ✅ All tests passing
- ✅ 0 compilation errors, 0 dialyzer warnings

**Enhanced Testability**:
- Pure domain functions can be tested without I/O mocking
- Infrastructure adapters provide clean testing boundaries
- Property-based testing becomes viable for business logic

### 📈 Benefits Realized

**Functional Architecture**:
1. **Pure Domain Logic**: Business rules separated from I/O operations
2. **Testability**: Functions with predictable inputs/outputs
3. **Maintainability**: Clear separation of concerns 
4. **Reliability**: Reduced bugs through pure functions
5. **Composability**: Domain functions easily combined and reused

**Clean Organization**:
1. **Consistent Patterns**: Every operation follows same structure
2. **No Redundancy**: Single consolidated shared directory
3. **Clear Boundaries**: I/O orchestration vs pure domain logic
4. **Enhanced Readability**: Logical grouping of related functionality

### 🚀 Ready for Phase 3

The refactor sets up excellent foundation for comprehensive testing:
- Pure domain functions ready for property-based testing
- Infrastructure adapters ready for clean mocking
- Clear test boundaries established
- Enhanced testability across all operations

---

**Files Changed**: 50+ files across contexts, workers, infrastructure, and web layer
**Lines of Code**: Significant reorganization with zero functional changes
**Architecture**: Successfully implemented functional domain modeling principles
**Quality**: 100% backward compatibility maintained 