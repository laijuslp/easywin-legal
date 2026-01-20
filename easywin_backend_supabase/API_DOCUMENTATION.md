# 🔒 EASYWIN 1.0 — BACKEND API DOCUMENTATION

**SSOT · Production-Ready · Supabase + PostgreSQL**

---

## 📋 TABLE OF CONTENTS

1. [Overview](#overview)
2. [Authentication](#authentication)
3. [Assessment & Learning Engine](#assessment--learning-engine)
4. [Coins & Monetization](#coins--monetization)
5. [Leaderboard & Profile](#leaderboard--profile)
6. [Content Management](#content-management)
7. [Error Handling](#error-handling)
8. [Security & RLS](#security--rls)
9. [Welcome Coins](#welcome-coins)

---

## 🎯 OVERVIEW

### Architecture
- **Backend**: Supabase (PostgreSQL + Auth + Storage)
- **Security**: Row Level Security (RLS) on all tables
- **Mutations**: All via RPC functions (server-side only)
- **Immutability**: Assessment attempts and coin transactions are immutable
- **Welcome Coins**: Exactly 50 coins once, immediately after first sign-up.
### Base URL
```
https://your-project.supabase.co
```

### Authentication
All RPCs require authentication via Supabase Auth JWT token.

---

## 🔐 AUTHENTICATION

### Sign Up
```javascript
const { data, error } = await supabase.auth.signUp({
  email: 'user@example.com',
  password: 'password123',
  options: {
    data: {
      display_name: 'John Doe'
    }
  }
})
```

### Sign In
```javascript
const { data, error } = await supabase.auth.signInWithPassword({
  email: 'user@example.com',
  password: 'password123'
})
```

### Sign Out
```javascript
const { error } = await supabase.auth.signOut()
```

---

## 🧠 ASSESSMENT & LEARNING ENGINE

### 1. Start Assessment

**RPC**: `start_assessment`

**Description**: Start an assessment session (A1, A2, or A3) with automatic cooldown enforcement.

**Parameters**:
```typescript
{
  p_quiz_id?: UUID,      // Either quiz_id or exam_id (not both)
  p_exam_id?: UUID
}
```

**Returns**:
```typescript
{
  success: boolean,
  assessment_type: 'assessment_1' | 'assessment_2' | 'assessment_3',
  questions: Array<{
    id: UUID,
    question_text: string,
    options: Array<{ key: 'A'|'B'|'C'|'D', text: string }>,
    correct_option: 'A'|'B'|'C'|'D',
    explanation: string
  }>,
  time_limit_seconds: number,
  time_per_question: number
}
```

**Example**:
```javascript
const { data, error } = await supabase.rpc('start_assessment', {
  p_quiz_id: 'uuid-here'
})
```

**Business Rules**:
- First access → Assessment 1
- After A1 → A2 locked for 24h
- After A2 → A3 locked for 24h
- After A3 → Can re-attempt A3 every 24h (overwrites previous)
- Questions randomized at session start
- Learning mode always available

---

### 2. Submit Assessment

**RPC**: `submit_assessment`

**Description**: Submit assessment answers and get score (server-side calculation).

**Parameters**:
```typescript
{
  p_quiz_id?: UUID,
  p_exam_id?: UUID,
  p_assessment_type: 'assessment_1' | 'assessment_2' | 'assessment_3',
  p_answers: Array<{
    question_id: UUID,
    selected_option: 'A'|'B'|'C'|'D'
  }>,
  p_time_taken_seconds: number
}
```

**Returns**:
```typescript
{
  success: boolean,
  attempt_id: UUID,
  score: number,              // 0-100
  correct_answers: number,
  total_questions: number,
  next_cooldown_unlocks_at: timestamp
}
```

**Example**:
```javascript
const { data, error } = await supabase.rpc('submit_assessment', {
  p_quiz_id: 'uuid-here',
  p_assessment_type: 'assessment_1',
  p_answers: [
    { question_id: 'q1-uuid', selected_option: 'A' },
    { question_id: 'q2-uuid', selected_option: 'C' }
  ],
  p_time_taken_seconds: 120
})
```

**Business Rules**:
- Score calculated server-side (prevents cheating)
- A1 & A2 are immutable (one attempt only)
- A3 can be overwritten every 24h
- Leaderboard updated automatically
- User stats updated

---

### 3. Start Learning Session

**RPC**: `start_learning_session`

**Description**: Start unlimited practice session (not recorded).

**Parameters**:
```typescript
{
  p_quiz_id?: UUID,
  p_exam_id?: UUID
}
```

**Returns**:
```typescript
{
  success: boolean,
  session_type: 'learning',
  questions: Array<Question>,  // Same format as assessment
  note: 'Learning mode — scores are not recorded'
}
```

**Example**:
```javascript
const { data, error } = await supabase.rpc('start_learning_session', {
  p_quiz_id: 'uuid-here'
})
```

**Business Rules**:
- Always available (no cooldown)
- Never recorded
- Never affects leaderboard
- Same question set as assessments

---

### 4. Get Assessment Status

**RPC**: `get_assessment_status`

**Description**: Get current assessment status and cooldowns.

**Parameters**:
```typescript
{
  p_quiz_id?: UUID,
  p_exam_id?: UUID
}
```

**Returns**:
```typescript
{
  success: boolean,
  assessment_1: {
    completed: boolean,
    score?: number,
    completed_at?: timestamp
  },
  assessment_2: {
    completed: boolean,
    score?: number,
    completed_at?: timestamp,
    unlocks_at?: timestamp,
    is_locked: boolean
  },
  assessment_3: {
    completed: boolean,
    score?: number,
    completed_at?: timestamp,
    unlocks_at?: timestamp,
    is_locked: boolean
  },
  next_assessment: 'assessment_1' | 'assessment_2' | 'assessment_3',
  learning_available: true
}
```

---

## 💰 COINS & MONETIZATION

### 1. Get Coin Balance

**RPC**: `get_coin_balance`

**Returns**:
```typescript
{
  success: boolean,
  available_coins: number,
  total_coins: number,
  spent_coins: number
}
```

---

### 2. Award Coins

**RPC**: `award_coins`

**Description**: Award or deduct coins (immutable ledger).

**Parameters**:
```typescript
{
  p_amount: number,           // Positive = award, Negative = deduct
  p_transaction_type: 'purchase' | 'unlock_quiz' | 'unlock_exam' | 
                      'unlock_category' | 'ad_reward' | 'daily_bonus' | 
                      'achievement_reward' | 'refund' | 'admin_adjustment',
  p_description?: string,
  p_reference_id?: UUID,
  p_metadata?: JSONB
}
```

**Returns**:
```typescript
{
  success: boolean,
  transaction_id: UUID,
  amount: number,
  previous_balance: number,
  new_balance: number
}
```

---

### 3. Unlock Content

**RPC**: `unlock_content`

**Description**: Unlock category, quiz, or exam using coins.

**Parameters**:
```typescript
{
  p_category_id?: UUID,
  p_quiz_id?: UUID,
  p_exam_id?: UUID
}
```

**Returns**:
```typescript
{
  success: boolean,
  message: string,
  coins_spent: number,
  new_balance?: number
}
```

---

### 4. Watch Ad Reward

**RPC**: `watch_ad_reward`

**Description**: Award coins for watching ads (max 10/day).

**Parameters**:
```typescript
{
  p_ad_unit_id: string,
  p_coins_earned?: number  // Default: 10
}
```

**Returns**:
```typescript
{
  success: boolean,
  coins_earned: number,
  new_balance: number,
  ads_watched_today: number,
  max_daily_ads: 10
}
```

---

### 5. Purchase Coin Pack

**RPC**: `purchase_coin_pack`

**Description**: Process IAP coin pack purchase.

**Parameters**:
```typescript
{
  p_pack_id: UUID,
  p_purchase_token: string,
  p_product_id: string
}
```

**Returns**:
```typescript
{
  success: boolean,
  coins_purchased: number,
  new_balance: number
}
```

---

### 6. Activate Subscription

**RPC**: `activate_subscription`

**Description**: Activate Pro/Premium subscription.

**Parameters**:
```typescript
{
  p_account_type: 'pro' | 'premium',
  p_product_id: string,
  p_purchase_token: string,
  p_duration_days?: number  // Default: 30
}
```

**Returns**:
```typescript
{
  success: boolean,
  subscription_id: UUID,
  account_type: 'pro' | 'premium',
  starts_at: timestamp,
  expires_at: timestamp
}
```

---

### 7. Check Content Access

**RPC**: `check_content_access`

**Description**: Check if user has access to content.

**Parameters**:
```typescript
{
  p_category_id?: UUID,
  p_quiz_id?: UUID,
  p_exam_id?: UUID
}
```

**Returns**:
```typescript
{
  success: boolean,
  has_access: boolean,
  is_unlocked: boolean,
  unlock_cost: number,
  requires_subscription: boolean,
  min_account_type: 'free' | 'pro' | 'premium',
  user_account_type: 'free' | 'pro' | 'premium'
}
```

---

### 8. Get Coin Transaction History

**RPC**: `get_coin_transaction_history`

**Parameters**:
```typescript
{
  p_limit?: number,   // Default: 50
  p_offset?: number   // Default: 0
}
```

**Returns**:
```typescript
{
  success: boolean,
  transactions: Array<{
    id: UUID,
    transaction_type: string,
    amount: number,
    balance_after: number,
    description: string,
    created_at: timestamp
  }>,
  total_count: number,
  limit: number,
  offset: number
}
```

---

## 🏆 LEADERBOARD & PROFILE

### 1. Get Leaderboard

**RPC**: `get_leaderboard`

**Description**: Get leaderboard for specific quiz/exam.

**Parameters**:
```typescript
{
  p_quiz_id?: UUID,
  p_exam_id?: UUID,
  p_assessment_type?: 'assessment_1' | 'assessment_2' | 'assessment_3',  // Default: 'assessment_3'
  p_limit?: number,   // Default: 100
  p_offset?: number   // Default: 0
}
```

**Returns**:
```typescript
{
  success: boolean,
  assessment_type: string,
  leaderboard: Array<{
    rank: number,
    user_id: UUID,
    display_name: string,
    username: string,
    avatar_url: string,
    score: number,
    completed_at: timestamp
  }>,
  total_count: number,
  user_rank?: number,
  user_score?: number
}
```

---

### 2. Get Global Leaderboard

**RPC**: `get_global_leaderboard`

**Parameters**:
```typescript
{
  p_limit?: number,
  p_offset?: number
}
```

**Returns**:
```typescript
{
  success: boolean,
  leaderboard: Array<{
    rank: number,
    user_id: UUID,
    display_name: string,
    username: string,
    avatar_url: string,
    total_score: number,
    quizzes_completed: number,
    exams_completed: number,
    account_type: string
  }>,
  total_count: number,
  user_rank?: number,
  user_score?: number
}
```

---

### 3. Get User Profile

**RPC**: `get_user_profile`

**Parameters**:
```typescript
{
  p_user_id?: UUID  // If null, returns current user's profile
}
```

**Returns**:
```typescript
{
  success: boolean,
  profile: {
    id: UUID,
    email?: string,              // Only for own profile
    username: string,
    display_name: string,
    avatar_url: string,
    account_type: string,
    total_coins?: number,        // Only for own profile
    available_coins?: number,    // Only for own profile
    spent_coins?: number,        // Only for own profile
    total_score: number,
    quizzes_completed: number,
    exams_completed: number,
    current_streak: number,
    longest_streak: number,
    last_activity_date: date,
    created_at: timestamp
  },
  is_own_profile: boolean
}
```

---

### 4. Update User Profile

**RPC**: `update_user_profile`

**Parameters**:
```typescript
{
  p_display_name?: string,
  p_username?: string,
  p_avatar_url?: string
}
```

**Returns**: Same as `get_user_profile`

---

### 5. Update Streak

**RPC**: `update_streak`

**Description**: Update daily streak (call after completing assessment/quiz).

**Returns**:
```typescript
{
  success: boolean,
  current_streak: number,
  longest_streak: number,
  streak_continued: boolean
}
```

---

### 6. Get User Dashboard

**RPC**: `get_user_dashboard`

**Description**: Get complete dashboard data.

**Returns**:
```typescript
{
  success: boolean,
  profile: {
    display_name: string,
    avatar_url: string,
    account_type: string,
    total_score: number,
    quizzes_completed: number,
    exams_completed: number,
    current_streak: number,
    longest_streak: number
  },
  recent_assessments: Array<{
    id: UUID,
    quiz_id?: UUID,
    exam_id?: UUID,
    assessment_type: string,
    score: number,
    correct_answers: number,
    total_questions: number,
    completed_at: timestamp,
    quiz_title?: string,
    exam_title?: string
  }>,
  coin_balance: { ... },
  subscription?: {
    account_type: string,
    status: string,
    expires_at: timestamp
  }
}
```

---

### 7. Complete Onboarding Phase

**RPC**: `complete_onboarding_phase`

**Parameters**:
```typescript
{
  p_phase: 1 | 2 | 3 | 4
}
```

**Returns**:
```typescript
{
  success: boolean,
  completed_phase: number,
  onboarding_completed: boolean,
  next_phase?: number
}
```

---

## 📚 CONTENT MANAGEMENT

### Get Categories
```javascript
const { data, error } = await supabase
  .from('categories')
  .select('*')
  .eq('is_active', true)
  .order('display_order')
```

### Get Quizzes by Category
```javascript
const { data, error } = await supabase
  .from('quizzes')
  .select('*')
  .eq('category_id', categoryId)
  .eq('is_active', true)
  .order('display_order')
```

### Get Exams by Category
```javascript
const { data, error } = await supabase
  .from('exams')
  .select('*')
  .eq('category_id', categoryId)
  .eq('is_active', true)
  .order('display_order')
```

### Get Coin Packs
```javascript
const { data, error } = await supabase
  .from('coin_packs')
  .select('*')
  .eq('is_active', true)
  .order('display_order')
```

---

## ⚠️ ERROR HANDLING

All RPCs return a consistent error format:

```typescript
{
  success: false,
  error: string  // Human-readable error message
}
```

### Common Errors

| Error | Meaning |
|-------|---------|
| `User not authenticated` | No valid JWT token |
| `User is banned` | Account is banned |
| `Assessment is on cooldown` | Must wait for cooldown |
| `Insufficient coins` | Not enough coins for operation |
| `Username already taken` | Username conflict |
| `Invalid or inactive coin pack` | Pack not found/active |
| `Daily ad limit reached` | Max 10 ads/day |

---

## 🔒 SECURITY & RLS

### Row Level Security (RLS)

All tables have RLS enabled. Policies enforce:

1. **Profiles**: Users can view all, update only own
2. **Assessment Attempts**: Users can view only own
3. **Coin Transactions**: Users can view only own (immutable)
4. **Leaderboard**: Public read, server-write only
5. **Questions**: Public read (after access check)

### Server-Side Enforcement

**ALL mutations go through RPCs**:
- ✅ Assessment scoring
- ✅ Coin transactions
- ✅ Welcome coin grant
- ✅ Cooldown enforcement
- ✅ Leaderboard updates
- ✅ Access control

**Client CANNOT**:
- ❌ Insert assessment attempts directly
- ❌ Modify coin balances
- ❌ Bypass cooldowns
- ❌ Manipulate scores

---

## 🎁 WELCOME COINS

### 1. Grant Welcome Coins

**RPC**: `grant_welcome_coins`

**Description**: Grant 50 welcome coins to the authenticated user once and only once. 

**Business Rules**:
- Granted only after first successful sign-up
- Exactly 50 coins (fixed)
- Recorded in ledger
- One-time grant locked by `welcome_coins_granted` flag

### 🛡️ FINAL SSOT STATEMENT
> **EasyWin 1.0 grants exactly 50 welcome coins once, immediately after first sign-up. This grant is enforced server-side and permanently recorded.**

---

## 🚀 DEPLOYMENT

### Migration Files

Apply migrations in order:
1. `20260106000000_easywin_v1_complete_schema.sql`
2. `20260106000001_easywin_v1_rls_policies.sql`
3. `20260106000002_easywin_v1_assessment_rpcs.sql`
4. `20260106000003_easywin_v1_coins_monetization_rpcs.sql`
5. `20260106000004_easywin_v1_leaderboard_profile_rpcs.sql`

### Supabase CLI

```bash
# Link project
supabase link --project-ref your-project-ref

# Push migrations
supabase db push

# Generate types (optional)
supabase gen types typescript --local > lib/database.types.ts
```

---

## 📝 NOTES

1. **All timestamps are UTC**
2. **All RPCs require authentication** (except public reads)
3. **Coin transactions are immutable** (audit trail)
4. **Assessment attempts are immutable** (A1 & A2 only)
5. **Leaderboard updates automatically** on assessment submission
6. **Learning mode never affects leaderboard**
7. **Cooldowns are 24 hours** (configurable server-side)

---

**STATUS**: ✅ Production-Ready · SSOT · EasyWin 1.0
