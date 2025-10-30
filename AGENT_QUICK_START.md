# Agent Quick Start Guide

## 🚀 Starting Milestone 1: Run These Agents in Order

### **Step 1: Initialize Project** (1 agent, ~30 min)

**Copy this prompt to Agent 1:**

```
I need to initialize a new Expo project with TypeScript for a social bingo app.
Please follow the instructions in MILESTONE_1_AGENT_STRATEGY.md, Phase 1A.

Create the project, folder structure, essential dependencies, and configuration files.
Once complete, verify it runs with `npx expo start`.
```

---

### **Step 2: Parallel Work** (2-3 agents simultaneously, ~40 min total)

**After Step 1 completes, start these in parallel:**

#### **Agent 2: Firebase Setup**

```
Phase 1A is complete. Set up Firebase integration following Phase 1B
in MILESTONE_1_AGENT_STRATEGY.md. Install packages, create services,
and configure Firebase Auth, Firestore, and Storage.
```

#### **Agent 3: Navigation Shell**

```
Phase 1A is complete. Create the navigation structure following Phase 1C
in MILESTONE_1_AGENT_STRATEGY.md. Build all navigators and placeholder screens.
```

#### **Agent 4: Theme & Components**

```
Phase 1A is complete. Build the design system following Phase 1D
in MILESTONE_1_AGENT_STRATEGY.md. Create theme files and reusable UI components.
```

---

### **Step 3: Data Model** (1 agent, after Step 2 Agent 2 completes, ~30 min)

**Agent 5 Prompt:**

```
Phase 1B (Firebase) is complete. Create the data model and TypeScript types
following Phase 1E in MILESTONE_1_AGENT_STRATEGY.md.
```

---

### **Step 4: Security Rules** (1 agent, after Step 3, ~25 min)

**Agent 6 Prompt:**

```
Phase 1E (Data Model) is complete. Create Firestore and Storage security rules
following Phase 1F in MILESTONE_1_AGENT_STRATEGY.md.
```

---

### **Step 5: Integration** (1 agent, after Steps 2-4 complete, ~30 min)

**Agent 7 Prompt:**

```
All Milestone 1 phases are complete. Please:
1. Review all created files
2. Wire up Firebase auth to navigation (guest sign-in → show MainNavigator)
3. Apply theme consistently to all screens
4. Test the complete flow end-to-end
5. Fix any integration issues
6. Verify TypeScript compiles without errors
```

---

## 📋 Agent Communication Template

When an agent completes their phase, have them report:

```
✅ Phase [X] Complete
- Created: [list files]
- Key features: [list]
- Ready for: [next phase names]
- Notes: [any issues or decisions made]
```

---

## ⚡ Efficiency Tips

1. **Run 3 agents in parallel** during Step 2 (Firebase, Navigation, Theme) - they don't conflict
2. **Share context files**: Always include `MILESTONE_1_AGENT_STRATEGY.md` and `TECHNICAL_ARCHITECTURE.md` in agent context
3. **Test immediately**: After each phase, verify the project still compiles
4. **Sequential where needed**: Data Model → Security Rules must be sequential (depends on types)

---

## 🎯 Expected Timeline

- **Sequential approach**: ~4 hours
- **Parallel approach**: ~2 hours (50% faster!)

---

## 📁 Key Files Agents Will Reference

- `MILESTONE_1_AGENT_STRATEGY.md` - Detailed task breakdown
- `TECHNICAL_ARCHITECTURE.md` - System design
- `REQUIREMENTS.md` - Feature requirements
- `DEVELOPMENT_ROADMAP.md` - Overall timeline

---

## ✅ Milestone 1 Completion Checklist

Before moving to Milestone 2, verify:

- [ ] Project runs: `npx expo start`
- [ ] TypeScript compiles: `npx tsc --noEmit`
- [ ] Firebase initializes (emulator or real config)
- [ ] Can navigate: Auth → Main → Game screens
- [ ] Guest "sign in" works and shows Home screen
- [ ] Theme applied to all screens
- [ ] Security rules deployed
- [ ] No linting errors

---

## 🐛 Common Issues & Fixes

**Issue:** Agent creates conflicting file structure  
**Fix:** Reference exact paths from MILESTONE_1_AGENT_STRATEGY.md

**Issue:** Firebase types don't match  
**Fix:** Share `/src/types/firebase.ts` with all Firebase-related agents

**Issue:** Navigation crashes  
**Fix:** Verify all screens are imported correctly in navigator files

**Issue:** Theme not applying  
**Fix:** Ensure theme provider wraps RootNavigator in App.tsx

---

Ready to start? Begin with **Step 1** above! 🚀
