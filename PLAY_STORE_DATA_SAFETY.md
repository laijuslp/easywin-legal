# EasyWin 1.0 - Play Store Data Safety Declaration

## Data Collection & Usage

### Data Types Collected

#### Personal Information
- **Email Address** (Optional)
  - Purpose: Account creation and authentication
  - Collection: User-provided during sign-up
  - Sharing: Not shared with third parties
  - Deletion: Deleted upon account deletion

#### App Activity
- **Quiz Attempts** (Required)
  - Purpose: Track learning progress and performance
  - Collection: Automatic when user takes quizzes
  - Retention: 90 days for raw data, 24 months for aggregates
  - Sharing: Not shared with third parties
  - Deletion: Automatically purged per retention policy

- **Question Answers** (Required)
  - Purpose: Scoring and performance analytics
  - Collection: Automatic during quiz attempts
  - Retention: 30 days
  - Sharing: Not shared with third parties
  - Deletion: Automatically purged after 30 days

#### App Performance
- **Crash Logs** (Required)
  - Purpose: App stability and bug fixes
  - Collection: Automatic on app crash
  - Retention: 30 days
  - Sharing: Not shared with third parties
  - Deletion: Automatically purged after 30 days

- **Diagnostics** (Required)
  - Purpose: App performance monitoring
  - Collection: Automatic during app usage
  - Retention: 30 days
  - Sharing: Not shared with third parties
  - Deletion: Automatically purged after 30 days

### Data NOT Collected

❌ **We DO NOT collect:**
- Location data (GPS, IP address)
- Device identifiers (GAID, IDFA, IMEI)
- Phone number
- Contacts
- Photos or videos
- Audio
- Calendar
- SMS or call logs
- Browsing history
- Search history
- Cross-app tracking data
- Advertising identifiers

## Data Security

### Encryption
- ✅ Data encrypted in transit (TLS 1.3)
- ✅ Data encrypted at rest (AES-256)
- ✅ Database-level encryption (Supabase)

### Access Control
- ✅ Row Level Security (RLS) on all tables
- ✅ Role-based access control (RBAC)
- ✅ Multi-factor authentication for admins
- ✅ Audit logging for all admin actions

## Data Retention & Deletion

### Automatic Retention Policies

| Data Type | Retention Period | Deletion Type |
|-----------|------------------|---------------|
| Quiz Attempts (Raw) | 90 days | Hard Delete |
| Question Answers | 30 days | Hard Delete |
| Aggregated Scores | 24 months | Archive |
| Best Scores | Until account deletion | Hard Delete |
| Coin Transactions | 12 months | Archive |
| Ad Watch Logs | 90 days | Hard Delete |
| Abuse Reports | 24 months | Anonymize |
| Admin Audit Logs | 36 months | Archive |
| API Logs | 30 days | Hard Delete |
| Error Logs | 30 days | Hard Delete |
| Security Events | 180 days | Archive |

### User-Initiated Deletion

#### Partial Deletion
- **What's deleted:** Learning history, quiz attempts, answers
- **What's kept:** Account, coins, best scores
- **Process:** Anonymized (user_id removed)
- **Timeline:** ≤7 days
- **Reversible:** No (irreversible after 7-day grace period)

#### Full Account Deletion
- **What's deleted:** Profile, attempts, scores, coins (hard delete)
- **What's kept:** Anonymized logs (legal basis), abuse records
- **Process:** 7-day grace period, then permanent deletion
- **Timeline:** ≤30 days for complete purge
- **Reversible:** Yes, within 7-day grace period

### Inactive Account Purging

| Inactivity Period | Action |
|-------------------|--------|
| 12 months | Purge raw quiz attempts |
| 24 months | Anonymize aggregated scores |
| 36 months | Auto-delete account (with email notice) |

## Data Sharing

### Third-Party Sharing
**We DO NOT share user data with third parties.**

### Service Providers
- **Supabase** (Database & Authentication)
  - Purpose: Data storage and user authentication
  - Data shared: All collected data (encrypted)
  - Location: US (SOC 2 Type II certified)
  - Privacy policy: https://supabase.com/privacy

### Legal Requirements
Data may be disclosed if required by law or to:
- Comply with legal process
- Protect rights and safety
- Prevent fraud or abuse

## User Rights

### Access
✅ Users can view their own data via app settings

### Correction
✅ Users can update profile information

### Deletion
✅ Users can request partial or full deletion
- Self-service deletion via app settings
- 7-day grace period with cancel option
- Email confirmation required

### Export
✅ Users can export their data (JSON format)
- Quiz history
- Performance stats
- Coin transaction history

## Privacy-First Analytics

### What We Track
- Quiz starts, completions, abandons
- Question interactions (seen, answered, skipped)
- Retry behavior
- Time spent (quiz-level only)
- Coin earnings and spending

### What We DON'T Track
- Individual question view time
- Behavioral surveillance
- Cross-app activity
- Ad network identifiers
- Personal identifiers in analytics

### Identifiers Used
- Internal user_id (UUID only)
- Session ID
- Rotating device hash (no GAID/IDFA)

## Compliance

### GDPR Compliance
✅ Right to access
✅ Right to rectification
✅ Right to erasure ("right to be forgotten")
✅ Right to data portability
✅ Right to object
✅ Privacy by design
✅ Data minimization
✅ Purpose limitation

### COPPA Compliance
✅ No collection from children under 13
✅ Age verification required
✅ Parental consent mechanism

### CCPA Compliance
✅ Right to know
✅ Right to delete
✅ Right to opt-out
✅ No sale of personal information

## Contact

**Data Protection Officer:**
Email: privacy@easywin.app

**Data Deletion Requests:**
Email: deletion@easywin.app
Response time: ≤7 days

**Privacy Policy:**
https://easywin.app/privacy

**Terms of Service:**
https://easywin.app/terms

---

## Play Store Questionnaire Answers

### Does your app collect or share any of the required user data types?
**Yes**

### Data types collected:
- [x] Email address (optional, for account)
- [x] App activity (quiz attempts, answers)
- [x] App performance (crash logs, diagnostics)

### Is all of the user data collected by your app encrypted in transit?
**Yes** - TLS 1.3

### Do you provide a way for users to request that their data is deleted?
**Yes** - Self-service deletion in app settings + email request

### Data retention and deletion:
**Automatic deletion** - Data is automatically deleted per retention policies (30-90 days for most data)

### Is this data required for your app, or can users choose whether it's collected?
- Email: **Optional** (can use anonymous account)
- Quiz attempts: **Required** (core functionality)
- Crash logs: **Required** (app stability)

### Why is this user data collected?
- **App functionality** - Quiz attempts and answers
- **Analytics** - Performance metrics (aggregated only)
- **Developer communications** - Email for account recovery

### Is this data shared with third parties?
**No** - Data is not shared with third parties

---

**Last Updated:** 2026-01-20
**Version:** 1.0
**Effective Date:** 2026-01-20
