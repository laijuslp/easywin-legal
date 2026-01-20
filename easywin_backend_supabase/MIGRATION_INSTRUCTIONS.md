# Content Authoring & Operations Migration

## Migration File
`20260112170717_content_authoring_and_ops.sql`

## What Was Added

### 1️⃣ Content Authoring & Versioning (Admin-Only)
- **`question_bank`** - Separates content creation from live questions
- **`question_versions`** - Version history with rollback capability
- **`question_reviews`** - Approval workflow tracking
- **`content_state` enum** - Draft → In Review → Approved → Published

**Benefits:**
✅ Protects live questions from incomplete content
✅ Enables rollback to previous versions
✅ Matches Admin SSOT documentation
✅ No auto-publishing (manual approval required)

### 2️⃣ Offline Attempt Sync Safety
- **`offline_attempts`** - Tracks offline quiz/exam attempts
- **`offline_status` enum** - Pending → Syncing → Synced/Failed
- **Coin escrow** - Reserves coins during offline play

**Benefits:**
✅ Prevents coin abuse from offline replay attacks
✅ Enables reliable sync with conflict resolution
✅ Matches offline SSOT specification

### 3️⃣ Feature Flags (Safe Rollouts)
- **`feature_flags`** - Controls feature availability
- **Gradual rollout** - Percentage-based rollout support
- **Kill switches** - Disable features without deployment

**Benefits:**
✅ Required for QA & release gates
✅ A/B testing capability
✅ Zero client trust model

### 4️⃣ Ops & Abuse Governance
- **`abuse_flags`** - Tracks fraud and abuse incidents
- **Severity levels** - 1-5 priority system
- **Resolution tracking** - Open → Investigating → Resolved/Dismissed

**Benefits:**
✅ Required for ops dashboard
✅ Fraud detection without score manipulation
✅ Audit trail for moderation actions

### 5️⃣ Row Level Security (RLS)
- RLS **enabled** on all new tables
- **No policies added yet** (waiting for role mapping finalization)

## What Was NOT Modified

❌ `questions` table - unchanged
❌ `attempts` table - unchanged
❌ `profiles` table - unchanged
❌ No admin score edit capabilities added
❌ No auto-publishing mechanisms
❌ No merging of authoring and live tables

## How to Apply

### Option 1: Supabase CLI (Recommended)
```bash
cd f:\easywin\easywin_backend_supabase
supabase db push
```

### Option 2: Supabase Dashboard
1. Go to SQL Editor in Supabase Dashboard
2. Copy contents of migration file
3. Execute SQL
4. Verify tables in Table Editor

### Option 3: Manual Migration
```bash
supabase migration up
```

## Verification Checklist

After applying migration:

```sql
-- Verify new tables exist
SELECT table_name 
FROM information_schema.tables 
WHERE table_schema = 'public' 
AND table_name IN (
  'question_bank',
  'question_versions',
  'question_reviews',
  'offline_attempts',
  'feature_flags',
  'abuse_flags'
);

-- Verify RLS is enabled
SELECT tablename, rowsecurity 
FROM pg_tables 
WHERE schemaname = 'public' 
AND tablename IN (
  'question_bank',
  'question_versions',
  'question_reviews',
  'offline_attempts',
  'feature_flags',
  'abuse_flags'
);

-- Verify feature flags seeded
SELECT * FROM feature_flags;
```

Expected results:
- 6 new tables created
- RLS enabled on all 6 tables
- 5 feature flags inserted (offline_mode, content_authoring, etc.)

## Next Steps

1. **Apply Migration** - Use Supabase CLI or Dashboard
2. **Verify Schema** - Run verification queries above
3. **Define Roles** - Map admin/user roles in Supabase Auth
4. **Add RLS Policies** - Create policies after role mapping is complete
5. **Lock Migrations** - Commit to version control before frontend build

## Schema Diagram

```
┌─────────────────────────────────────────────────────────┐
│                 CONTENT AUTHORING                        │
├─────────────────────────────────────────────────────────┤
│  question_bank                                           │
│  ├── status: draft → in_review → approved → published   │
│  └── current_version_id → question_versions             │
│                                                           │
│  question_versions (audit trail)                         │
│  └── version_no (rollback capability)                    │
│                                                           │
│  question_reviews (approval workflow)                    │
│  └── decision: approved | rejected                       │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│                 OFFLINE SYNC                             │
├─────────────────────────────────────────────────────────┤
│  offline_attempts                                        │
│  ├── status: pending_sync → syncing → synced/failed     │
│  ├── coins_reserved (escrow)                             │
│  └── answers (JSONB)                                     │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│                 OPERATIONS                               │
├─────────────────────────────────────────────────────────┤
│  feature_flags                                           │
│  ├── enabled (kill switch)                               │
│  └── rollout_percentage (gradual release)                │
│                                                           │
│  abuse_flags                                             │
│  ├── severity (1-5)                                      │
│  └── status: open → investigating → resolved             │
└─────────────────────────────────────────────────────────┘
```

## Safety Guarantees

This migration follows strict safety rules:

✅ **Additive Only** - No existing tables modified
✅ **No Data Loss** - All operations are append-only
✅ **RLS Protected** - All tables have RLS enabled
✅ **Rollback Safe** - Can be reverted if needed
✅ **Zero Trust** - No client-side control over critical operations

## References

- Base Migration: `20260106000000_easywin_v1_combined.sql`
- Admin SSOT: `API_DOCUMENTATION.md`
- Session Complete: `SESSION_1_COMPLETE.md`
