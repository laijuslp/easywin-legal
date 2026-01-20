# EasyWin 1.0 - Assessment & Learning Engine SSOT Revision

## Terminology Update: Leaderboard → Assessment Ranking

**Version:** v1.0.1  
**Date:** 2026-01-20  
**Type:** Terminology Alignment (No Behavior Change)  
**Status:** FINAL · LOCKED · ENFORCEABLE

---

## 6. Assessment Ranking System (FINAL)

*(Previously referred to as "Leaderboard")*

### 6.1 Terminology Lock

The term **"Leaderboard"** is deprecated and MUST NOT appear in:
- ❌ UI
- ❌ API responses
- ❌ Database labels
- ❌ Documentation
- ❌ Admin dashboards

**The canonical term is:**
✅ **Assessment Ranking**

### 6.2 Structure

Assessment Ranking tabs are ordered as:
**Assessment 3 (default) → Assessment 2 → Assessment 1**

### 6.3 Tab Logic

**Assessment 3:**
- Represents mastery after learning
- May update every 24 hours
- Reflects the most recent valid Assessment 3 attempt

**Assessment 2:**
- Fixed permanently after submission
- Represents improvement after learning

**Assessment 1:**
- Fixed permanently after submission
- Represents first-exposure performance

### 6.4 Integrity Rules

- Scores never auto-upgrade between assessments
- Assessment tabs never replace each other
- Learning mode never appears in Assessment Ranking
- Rankings are derived only from Assessment submissions

### 6.5 UX Copy Rules

All user-facing text MUST use:
- ✅ "Assessment Ranking"
- ✅ "Assessment Performance"
- ✅ "Assessment Results"

❌ **The word "Leaderboard" must not be displayed anywhere in the product.**

### 6.6 SSOT Enforcement Statement

Assessment Ranking is:
- **Assessment-only** (Learning never appears)
- **Submission-based** (Only completed assessments)
- **Immutable per assessment level** (Assessment 1 & 2 never change)
- **Independent across Assessment 1, 2, and 3** (Separate rankings)

Any terminology or logic change requires:
- SSOT version increment
- Formal revision approval

---

## Implementation Changes

### Backend (SQL)

**Changed:**
- Column: `is_leaderboard_eligible` → `is_assessment_ranking_eligible`
- Index: `idx_assessment_attempts_leaderboard` → `idx_assessment_attempts_ranking`
- Function: `get_leaderboard()` → `get_assessment_ranking()`
- Comments: All references updated

**File:** `20260120140000_assessment_learning_engine.sql`

### Flutter (Dart)

**Changed:**
- Property: `isLeaderboardEligible` → `isAssessmentRankingEligible`
- Class: `LeaderboardEntry` → `AssessmentRankingEntry`
- Class: `LeaderboardState` → `AssessmentRankingState`

**File:** `assessment_state.dart`

### Documentation

**Changed:**
- All section headers
- All table references
- All code examples
- All testing checklists

**File:** `ASSESSMENT_LEARNING_IMPLEMENTATION_COMPLETE.md`

---

## Migration Guide

### For Existing Code

**Replace all instances:**

```dart
// OLD (DEPRECATED)
isLeaderboardEligible
LeaderboardEntry
LeaderboardState
get_leaderboard()

// NEW (CANONICAL)
isAssessmentRankingEligible
AssessmentRankingEntry
AssessmentRankingState
get_assessment_ranking()
```

### For UI Text

**Replace all instances:**

```
// OLD (DEPRECATED)
"Leaderboard"
"View Leaderboard"
"Top Players"

// NEW (CANONICAL)
"Assessment Ranking"
"View Assessment Ranking"
"Top Performers"
```

---

## Verification Checklist

- [x] Backend column renamed
- [x] Backend index renamed
- [x] Backend function renamed
- [x] Backend comments updated
- [x] Flutter property renamed
- [x] Flutter classes renamed
- [x] Documentation updated
- [x] Code examples updated
- [x] Testing checklist updated

---

## Status

**Terminology Update:** COMPLETE ✅  
**Behavior Change:** NONE  
**SSOT Compliance:** 100%  
**Breaking Changes:** YES (API naming only)

---

**Revision Date:** 2026-01-20  
**Approved By:** SSOT Authority  
**Status:** FINAL · LOCKED · ENFORCEABLE
