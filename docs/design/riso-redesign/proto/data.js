/* ============================================================
   OYBC · Riso prototype — sample data (window globals)
   ============================================================ */
(function () {
  // Cell types: 'normal' | 'count' | 'compound' | 'free'
  // The active demo board ("Weekly Wellness") is set up so the top row
  // is one tap from a BINGO and column 0 is one counting-tick away too.
  const wellnessCells = [
    { t: "Meditate", type: "normal", done: true },
    { t: "Run 5km", type: "count", cur: 5, max: 5, unit: "km" },
    { t: "Read 30 min", type: "normal", done: true },
    { t: "Drink water", type: "count", cur: 8, max: 8, unit: "cups" },
    { t: "Journal", type: "normal", done: false },

    { t: "Stretch", type: "normal", done: true },
    { t: "10k steps", type: "count", cur: 6, max: 10, unit: "k" },
    { t: "No sugar", type: "normal", done: true },
    { t: "Meal prep", type: "compound", cur: 2, max: 3, unit: "meals" },
    { t: "Sleep 8h", type: "normal", done: false },

    { t: "Walk dog", type: "normal", done: true },
    { t: "Tidy desk", type: "normal", done: false },
    { t: "FREE", type: "free", done: true },
    { t: "Gratitude", type: "normal", done: true },
    { t: "Spanish", type: "count", cur: 1, max: 3, unit: "lessons" },

    { t: "Push-ups", type: "count", cur: 20, max: 30, unit: "reps" },
    { t: "Inbox zero", type: "normal", done: false },
    { t: "Floss", type: "normal", done: true },
    { t: "Budget", type: "normal", done: false },
    { t: "Yoga", type: "normal", done: false },

    { t: "Plants", type: "normal", done: true },
    { t: "Early rise", type: "normal", done: false },
    { t: "Plan week", type: "normal", done: true },
    { t: "Read news", type: "normal", done: false },
    { t: "Call friend", type: "normal", done: false },
  ];

  // normalize count/compound done flags from cur/max
  wellnessCells.forEach(c => {
    if (c.type === "count" || c.type === "compound") c.done = c.cur >= c.max;
  });

  window.OYBC = {
    boards: [
      {
        id: "wellness", name: "Weekly Wellness", tf: "This week · 4 days left", tfKey: "weekly",
        status: "active", size: 5, bingos: 1, expiring: false, cells: wellnessCells,
      },
      {
        id: "morning", name: "Morning Routine", tf: "Today · resets tonight", tfKey: "daily",
        status: "active", size: 3, bingos: 0, expiring: false,
        cells: null, miniFill: [1,1,0,1,1,0,1,0,0], done: 4, total: 9,
      },
      {
        id: "fitness", name: "Fitness February", tf: "This month · expires soon", tfKey: "monthly",
        status: "active", size: 5, bingos: 2, expiring: true,
        cells: null, miniFill: [1,1,1,1,1,1,1,1,0,1,1,1,1,1,1,0,1,1,1,0,1,0,1,0,1], done: 18, total: 25,
      },
      {
        id: "books", name: "26 Books in '26", tf: "This year · on track", tfKey: "yearly",
        status: "active", size: 5, bingos: 1, expiring: false,
        cells: null, miniFill: [1,1,1,1,0,1,1,1,0,0,1,1,1,0,0,1,0,0,0,0,0,0,0,0,0], done: 11, total: 25,
      },
      {
        id: "marathon", name: "Marathon Block", tf: "Custom · 12 weeks · wk 5", tfKey: "custom",
        status: "active", size: 5, bingos: 0, expiring: false,
        cells: null, miniFill: [1,1,1,0,0,1,1,0,0,0,1,1,1,0,0,1,0,0,0,0,1,0,0,0,0], done: 9, total: 25,
      },
      {
        id: "money", name: "May Money Goals", tf: "May 2026 · complete", tfKey: "monthly",
        status: "completed", size: 5, bingos: 3, expiring: false,
        cells: null, miniFill: Array(25).fill(1), done: 25, total: 25,
      },
      {
        id: "reading", name: "Reading Sprint", tf: "Draft · not started", tfKey: "weekly",
        status: "draft", size: 5, bingos: 0, expiring: false,
        cells: null, miniFill: Array(25).fill(0), done: 0, total: 25,
      },
    ],

    // timeframe core boards for the boards-home top strip (one per timeframe)
    timeframes: [
      { key: "daily", label: "Daily", status: "Ready", state: "blue" },
      { key: "weekly", label: "Weekly", status: "Active", state: "green" },
      { key: "monthly", label: "Monthly", status: "Expiring", state: "warn" },
      { key: "yearly", label: "Yearly", status: "Active", state: "green" },
      { key: "custom", label: "Custom", status: "Empty", state: "empty" },
    ],

    // wizard step-2 seed tasks
    wizardTasks: [
      { t: "Meditate 10 min", type: "normal" },
      { t: "Run", type: "count", max: 5, unit: "km" },
      { t: "Read", type: "normal" },
      { t: "Drink water", type: "count", max: 8, unit: "cups" },
      { t: "Meal prep", type: "compound", max: 3, unit: "meals" },
      { t: "Journal", type: "normal" },
    ],

    // reusable task library (what reuse pulls from). uses = popularity, boards = # boards the task lives on.
    taskLibrary: [
      { id: "l1", t: "Meditate 10 min", type: "normal", uses: 23, boards: 4 },
      { id: "l2", t: "Drink water", type: "count", action: "Drink", max: 8, unit: "cups", uses: 19, boards: 3 },
      { id: "l3", t: "Read 30 min", type: "normal", uses: 17, boards: 3 },
      { id: "l4", t: "Walk the dog", type: "normal", uses: 14, boards: 2 },
      { id: "l5", t: "10k steps", type: "count", action: "Walk", max: 10, unit: "k steps", uses: 12, boards: 3 },
      { id: "l6", t: "Journal", type: "normal", uses: 11, boards: 2 },
      { id: "l7", t: "Morning routine", type: "compound", rule: "all", subs: [{t:"Make bed"},{t:"Stretch"},{t:"Cold shower"}], uses: 10, boards: 2 },
      { id: "l8", t: "Stretch", type: "normal", uses: 9, boards: 2, childOf: ["Morning routine"] },
      { id: "l9", t: "No sugar today", type: "normal", uses: 8, boards: 1 },
      { id: "l10", t: "Push-ups", type: "count", action: "Do", max: 30, unit: "reps", uses: 7, boards: 2 },
      { id: "l11", t: "Read 100 pages", type: "count", action: "Read", max: 100, unit: "pages", uses: 7, boards: 1 },
      { id: "l12", t: "Weekly reset", type: "compound", rule: "mOfN", threshold: 2, subs: [{t:"Tidy desk"},{t:"Plan week"},{t:"Clear inbox"}], uses: 6, boards: 1 },
      { id: "l13", t: "Meal prep", type: "compound", rule: "ordered", subs: [{t:"Plan menu"},{t:"Shop"},{t:"Cook"}], uses: 6, boards: 2 },
      { id: "l14", t: "Early to bed", type: "normal", uses: 6, boards: 1 },
      { id: "l15", t: "Inbox zero", type: "normal", uses: 5, boards: 1, childOf: ["Weekly reset"] },
      { id: "l16", t: "Gratitude note", type: "normal", uses: 5, boards: 1 },
      { id: "l17", t: "Learn Spanish", type: "count", action: "Do", max: 3, unit: "lessons", uses: 4, boards: 1 },
      { id: "l18", t: "Floss", type: "normal", uses: 4, boards: 1 },
      { id: "l19", t: "Budget check", type: "normal", uses: 3, boards: 1 },
      { id: "l20", t: "Finish reading challenge", type: "achievement", watch: "board", target: "26 Books in '26", trigger: "greenlog", uses: 1, boards: 1 },
    ],

    // source boards for the "From a board…" picker
    sourceBoards: [
      { id: "sb1", name: "Weekly Wellness", tf: "Weekly", tasks: ["Meditate 10 min", "Drink water", "Read 30 min", "Journal", "Stretch", "No sugar today"] },
      { id: "sb2", name: "Fitness February", tf: "Monthly", tasks: ["10k steps", "Push-ups", "Morning routine", "Early to bed"] },
      { id: "sb3", name: "26 Books in '26", tf: "Yearly", tasks: ["Read 100 pages", "Read 30 min"] },
    ],

    // watch targets for Achievement tasks (cross-board watchers)
    watchTargets: {
      boards: ["Weekly Wellness", "Fitness February", "26 Books in '26", "Marathon Block"],
      templates: ["Daily Routine", "Weekly Reset", "Monthly Goals"],
    },

    // curated starter packs for the cold start
    starterPacks: [
      { id: "wellness", name: "Wellness", glyph: "leaf", count: 12,
        tasks: ["Meditate 10 min", "Drink water", "Read 30 min", "Stretch", "Journal", "Gratitude note", "No sugar today", "Early to bed", "Walk the dog", "Floss", "Sunlight 15 min", "Deep breaths"] },
      { id: "fitness", name: "Fitness", glyph: "spark", count: 12,
        tasks: ["10k steps", "Push-ups", "Run", "Stretch", "Plank 2 min", "Squats", "Protein goal", "8h sleep", "Foam roll", "Yoga", "No elevator", "Hydrate"] },
      { id: "productivity", name: "Productivity", glyph: "block", count: 12,
        tasks: ["Inbox zero", "Plan the day", "Deep work 1h", "No phone AM", "One big thing", "Tidy desk", "Review goals", "Read industry news", "Ship something", "Log expenses", "Email triage", "Shutdown ritual"] },
      { id: "mindful", name: "Mindful", glyph: "dot", count: 9,
        tasks: ["Meditate 10 min", "Gratitude note", "Digital sunset", "Deep breaths", "Journal", "Stretch", "Sunlight 15 min", "Call a friend", "Single-task hour"] },
    ],
  };
})();
