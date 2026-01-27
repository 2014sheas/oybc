# @oybc/shared

Shared types, algorithms, and validation for OYBC (On Your Bingo Card).

## What's Inside

This package contains **pure TypeScript code only**:

- **Types**: TypeScript interfaces for all entities (Board, Task, BoardTask, etc.)
- **Constants**: Enums, configuration values
- **Validation**: Zod schemas for input validation
- **Algorithms**: (To be implemented)
  - Bingo detection
  - Board randomization (Fisher-Yates)
  - Calendar boundary calculations

## What's NOT Inside

- ❌ Database code (GRDB, Dexie, Room)
- ❌ Firebase code (Auth, Firestore)
- ❌ React components
- ❌ SwiftUI views
- ❌ Platform-specific code

## Usage

### In Web App (Next.js)

```typescript
import { Board, CreateBoardInput, CreateBoardInputSchema } from '@oybc/shared';

// Validate input
const result = CreateBoardInputSchema.safeParse(input);
if (!result.success) {
  console.error(result.error);
}
```

### In iOS App (Swift)

Convert TypeScript types to Swift structs manually, or use the types as reference for GRDB models.

## Development

```bash
# Build
pnpm build

# Watch mode
pnpm dev

# Run tests
pnpm test

# Run tests in watch mode
pnpm test:watch

# Coverage
pnpm test:coverage
```

## Testing

All algorithms MUST have comprehensive Jest tests with 80%+ coverage.

## Design Principles

1. **Pure logic only**: No side effects, no I/O
2. **Platform-agnostic**: Works in browser, Node.js, and as reference for Swift
3. **Well-tested**: All algorithms have tests
4. **Minimal dependencies**: Only zod for validation
5. **Offline-first**: Types designed for local-first architecture
