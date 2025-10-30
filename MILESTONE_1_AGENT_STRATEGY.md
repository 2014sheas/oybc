# Milestone 1: Agent Strategy & Workflow

## Overview

This document outlines how to efficiently leverage AI agents to complete Milestone 1 (Foundations) in the shortest time possible through parallelization and clear task decomposition.

## Agent Workflow Principles

### 1. **Parallelize Independent Work**

- Run multiple agents simultaneously on non-dependent tasks
- Use separate agent sessions for different components

### 2. **Establish Common Patterns Early**

- Create reusable templates/configs that all agents can reference
- Standardize file structure, naming, and code style upfront

### 3. **Use Agent Handoffs**

- One agent sets up infrastructure, another builds on top
- Clear "complete" signals between dependent tasks

### 4. **Test Incrementally**

- Each agent validates their work before marking complete
- Integration testing happens after parallel work merges

---

## Milestone 1 Breakdown: Agent Tasks

### **Phase 1A: Core Infrastructure (Sequential, 1 agent)**

**Dependencies:** None - Start here first  
**Time:** ~30 minutes  
**Agent Prompt:**

```
Initialize a new Expo project with TypeScript for the social bingo app:
1. Create project with: npx create-expo-app@latest --template
2. Add TypeScript configuration
3. Set up folder structure:
   - /src
     - /components (shared UI)
     - /screens (all screens)
     - /navigation (navigation configs)
     - /services (Firebase, API)
     - /utils (helpers)
     - /types (TypeScript interfaces)
     - /hooks (custom hooks)
     - /store (Redux if using, or context)
   - /config (env, constants)
   - /assets (images, fonts)
4. Install essential packages:
   - @react-navigation/native, @react-navigation/stack, @react-navigation/bottom-tabs
   - @react-native-async-storage/async-storage
   - react-native-safe-area-context, react-native-screens
   - expo-image-picker (for verification photos)
   - expo-camera (optional for now)
5. Set up ESLint + Prettier configs
6. Create a basic app theme (colors, typography, spacing)
7. Create .env.example file for Firebase config
8. Add .gitignore with Expo/Firebase/Node ignores
```

**Deliverables:**

- ✅ Working Expo project
- ✅ TypeScript configured
- ✅ Folder structure ready
- ✅ Essential dependencies installed
- ✅ Linting configured
- ✅ Basic theme file

**Test:** Run `npx expo start` and verify project builds

---

### **Phase 1B: Firebase Setup (Parallel to 1A completion)**

**Dependencies:** 1A (project structure)  
**Time:** ~20 minutes  
**Agent Prompt:**

```
Set up Firebase integration for the social bingo app:
1. Install Firebase packages:
   - firebase
   - @react-native-firebase/app (if needed, or use Firebase JS SDK)
2. Create /src/services/firebase/config.ts:
   - Initialize Firebase with environment variables
   - Export auth, firestore, storage instances
3. Create /src/services/firebase/auth.ts:
   - Email/password auth functions (signUp, signIn, signOut)
   - Guest user creation function
   - Auth state listener setup
4. Create /src/services/firebase/firestore.ts:
   - Type-safe Firestore helpers
   - Collection path constants
5. Create /src/types/firebase.ts:
   - TypeScript interfaces matching our data model (User, Game, etc.)
6. Set up initial Firestore security rules (basic structure, we'll refine later)
7. Create Firebase emulator setup instructions (firebase.json, .firebaserc)
8. Update .env.example with Firebase config placeholders
```

**Deliverables:**

- ✅ Firebase SDK configured
- ✅ Auth service ready
- ✅ Firestore service ready
- ✅ Type definitions
- ✅ Security rules skeleton
- ✅ Env config template

**Test:** Verify Firebase initializes without errors (even with dummy config)

---

### **Phase 1C: Navigation Shell (Parallel after 1A)**

**Dependencies:** 1A (React Navigation packages)  
**Time:** ~25 minutes  
**Agent Prompt:**

```
Create the navigation structure for the social bingo app:
1. Create /src/navigation/types.ts:
   - Define all navigation param types (AuthStackParamList, MainTabParamList, GameStackParamList)
2. Create /src/navigation/AuthNavigator.tsx:
   - Stack navigator for Login, Register, GuestJoin screens (placeholder screens for now)
3. Create /src/navigation/MainNavigator.tsx:
   - Tab navigator with: Home, Profile, Settings tabs (placeholder screens)
4. Create /src/navigation/GameNavigator.tsx:
   - Stack navigator for: CreateGame, JoinGame, GameLobby, GameBoard screens (placeholders)
5. Create /src/navigation/RootNavigator.tsx:
   - Conditional navigation (show AuthNavigator if not authenticated, MainNavigator if authenticated)
   - Handle loading state
6. Create placeholder screens in /src/screens:
   - Auth: LoginScreen, RegisterScreen, GuestJoinScreen
   - Main: HomeScreen, ProfileScreen, SettingsScreen
   - Game: CreateGameScreen, JoinGameScreen, GameLobbyScreen, GameBoardScreen
7. Each placeholder should have:
   - Basic layout with title
   - Navigation back button where appropriate
   - Styled with the theme
8. Update App.tsx to use RootNavigator
```

**Deliverables:**

- ✅ Complete navigation structure
- ✅ All placeholder screens exist
- ✅ Navigation types defined
- ✅ Conditional auth routing

**Test:** Navigate between screens to verify structure works

---

### **Phase 1D: Theme & Design System (Parallel to 1C)**

**Dependencies:** 1A (theme file exists)  
**Time:** ~20 minutes  
**Agent Prompt:**

```
Create a comprehensive design system for the social bingo app:
1. Enhance /src/theme/colors.ts:
   - Primary, secondary, accent colors
   - Success, error, warning colors
   - Background colors (light/dark mode ready)
   - Text colors
2. Create /src/theme/typography.ts:
   - Font families (system fonts for MVP)
   - Heading sizes (h1-h4)
   - Body text sizes
   - Label/caption sizes
3. Create /src/theme/spacing.ts:
   - Standard spacing scale (4, 8, 12, 16, 24, 32, etc.)
4. Create /src/theme/index.ts:
   - Export all theme values in a Theme type
5. Create /src/components/shared/Button.tsx:
   - Primary, secondary, outline variants
   - Size variants (small, medium, large)
   - Loading state
   - Disabled state
6. Create /src/components/shared/Input.tsx:
   - Text input with label
   - Error state
   - Placeholder styling
7. Create /src/components/shared/Card.tsx:
   - Basic card container with padding/shadow
8. Create /src/components/shared/LoadingSpinner.tsx
9. Create /src/components/shared/ErrorMessage.tsx
10. Apply theme to placeholder screens
```

**Deliverables:**

- ✅ Complete theme system
- ✅ Reusable UI components
- ✅ Consistent styling applied

**Test:** Verify components render correctly and theme is used consistently

---

### **Phase 1E: Data Model & Types (Parallel to 1B)**

**Dependencies:** 1B (Firebase types exist)  
**Time:** ~30 minutes  
**Agent Prompt:**

```
Create the complete data model and TypeScript types for MVP:
1. Create /src/types/user.ts:
   - User interface (matches Firebase User + our custom fields)
   - GuestUser type
2. Create /src/types/game.ts:
   - Game interface (MVP version: 3x3 board, owner-only events)
   - GameState enum
   - GameConfig interface
   - Player interface
3. Create /src/types/event.ts:
   - Event interface
   - VerificationType enum
4. Create /src/types/submission.ts:
   - Submission interface
   - SubmissionStatus enum
   - Evidence types
5. Create /src/types/board.ts:
   - Square interface
   - BoardLayout type
   - BingoLine type (for detection)
6. Create /src/constants/gameConstants.ts:
   - Board sizes (for future, but MVP is 3x3)
   - Max players (25)
   - Join code length (6)
7. Create /src/constants/firestorePaths.ts:
   - Collection path strings (users, games, etc.)
   - Helper functions for subcollection paths
8. Create validation functions in /src/utils/validation.ts:
   - validateGameName()
   - validateEventTitle()
   - validateJoinCode()
```

**Deliverables:**

- ✅ Complete TypeScript type system
- ✅ Constants file
- ✅ Validation utilities
- ✅ Firestore path helpers

**Test:** TypeScript compilation passes, types are used consistently

---

### **Phase 1F: Security Rules (After 1E)**

**Dependencies:** 1E (data model defined)  
**Time:** ~25 minutes  
**Agent Prompt:**

```
Create comprehensive Firestore security rules for MVP:
1. Create /firestore.rules file:
   - Users: Read own data, write own data
   - Games: Read if owner or player, write if owner (with validations)
   - Subcollections: gamePlayers, boards, submissions with appropriate access
   - Guest users: Limited read/write for games they joined
2. Create /firestore.indexes.json:
   - Indexes for common queries (games by owner, games by joinCode, etc.)
3. Create /storage.rules (Firebase Storage):
   - Rules for submission photos (game/{gameId}/submissions/{submissionId})
   - Only owner and submitter can read
   - Only authenticated users can write
4. Create /src/services/firebase/rules.test.ts (optional, for later):
   - Test cases for security rules
5. Document the rules in /docs/SECURITY_RULES.md:
   - Explain each rule's purpose
   - List edge cases handled
```

**Deliverables:**

- ✅ Firestore security rules
- ✅ Storage security rules
- ✅ Index definitions
- ✅ Documentation

**Test:** Deploy rules to Firebase emulator, test basic read/write scenarios

---

## Recommended Agent Execution Order

### **Session 1: Foundation (Sequential)**

```
Agent 1 → Phase 1A (Project Setup)
  ↓ (wait for completion)
Agent 2 → Phase 1B (Firebase Setup)
Agent 3 → Phase 1C (Navigation Shell)  [parallel with 1B]
Agent 4 → Phase 1D (Theme & Components) [parallel with 1C]
```

### **Session 2: Data & Security (Sequential-Parallel)**

```
Agent 5 → Phase 1E (Data Model & Types) [after 1B complete]
  ↓ (wait for completion)
Agent 6 → Phase 1F (Security Rules) [after 1E complete]
```

### **Session 3: Integration & Testing (One Agent)**

```
Agent 7 → Integration
- Connect Firebase auth to navigation
- Wire up theme to all screens
- Add basic error boundaries
- Create a simple "Hello World" flow:
  - Guest user can "sign in" → see Home screen
  - Can navigate to Create Game (shows placeholder)
  - Verify real-time updates don't crash
- Test Firebase emulator connection
```

---

## Parallel Agent Best Practices

### **1. Shared Context Files**

Create these FIRST, then share them with all agents:

- `MILESTONE_1_AGENT_STRATEGY.md` (this file)
- `TECHNICAL_ARCHITECTURE.md` (reference)
- `REQUIREMENTS.md` (reference)

### **2. Agent Communication**

When handing off:

```
"Phase 1A is complete. The project structure is in place at /src.
The theme file exists at /src/theme/index.ts but needs enhancement.
You can now proceed with Phase 1B (Firebase Setup)."
```

### **3. Conflict Avoidance**

- Each agent works in their assigned directory/files
- If overlap occurs (e.g., two agents touch theme), agent handling Phase 1D owns theme, others read-only
- Use clear file ownership

### **4. Testing Checkpoints**

After each phase completes:

- ✅ Code compiles
- ✅ No linting errors
- ✅ Files are properly formatted
- ✅ Imports resolve correctly

---

## Success Criteria for Milestone 1

### Technical

- [x] Expo app runs (`npx expo start`)
- [x] TypeScript compiles without errors
- [x] Firebase initializes (emulator or real)
- [x] Navigation works between all placeholder screens
- [x] Theme is consistently applied
- [x] Security rules deploy successfully
- [x] All types are properly defined

### Functional

- [x] Can navigate from Auth flow → Main tabs
- [x] Guest user "sign in" works (creates guest ID)
- [x] Screens render without crashes
- [x] Basic theme styling visible

### Code Quality

- [x] ESLint passes
- [x] Prettier formatting consistent
- [x] File structure matches design
- [x] Types are strict (no `any` except where necessary)

---

## Agent Prompt Templates

### For Phase X Completion

```
I've completed [Phase X]. Here's what was created:
- Files: [list]
- Key features: [list]
- Dependencies met: [list]
- Ready for: [next phases that can start]

Please verify the work compiles and then proceed with [assigned task].
```

### For Integration Agent

```
Milestone 1 phases 1A-1F are complete. Please:
1. Review all created files
2. Identify any missing connections
3. Create integration code to connect:
   - Firebase auth → Navigation state
   - Theme → All screens
   - Types → All services
4. Test the complete flow
5. Document any issues found
```

---

## Time Estimate

**Sequential (1 agent):** ~3-4 hours  
**With Parallelization (multiple agents):** ~1.5-2 hours

**Efficiency gain: ~50% time reduction**

---

## Next Steps After Milestone 1

Once Milestone 1 is complete, you'll have:

- ✅ Solid foundation
- ✅ Reusable components
- ✅ Type-safe codebase
- ✅ Firebase ready
- ✅ Navigation structure

This enables fast iteration on Milestone 2 (Core Features).
