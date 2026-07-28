# TS ↔ Swift mirror map

iOS does not consume this package at build time — Swift files are manual
mirrors (same algorithms, same semantics). When you change a TS module
here, update its Swift twin in the same PR (CLAUDE.md rule 6).

| bingo-core module | Swift mirror |
| --- | --- |
| src/bingoDetection.ts | apps/ios/OYBC/Services/BingoDetection.swift |
| src/shuffle.ts | apps/ios/OYBC/Services/Shuffle.swift (both the RNG-param canonical + the no-arg convenience overload) |
| src/centerSquare.ts | inline in `BoardPlacement.swift` (getCenterSquareIndex logic) + placement call sites (no dedicated Swift file) |
| src/placement.ts | apps/ios/OYBC/Services/BoardPlacement.swift |
| src/constants.ts | Swift enums in Database/Models (CenterSquareType), Int literals for BoardSize |
