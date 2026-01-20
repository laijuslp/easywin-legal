-- ============================================================================
-- EASYWIN 1.0 - DATA RETENTION & DELETION FRAMEWORK
-- SSOT for all retention policies, deletion workflows, and compliance
-- ============================================================================

-- PART 1: RETENTION POLICY CONFIGURATION (SSOT)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.retention_policies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    domain TEXT NOT NULL UNIQUE, -- e.g., 'quiz_attempts', 'coin_logs', 'api_logs'
    retention_days INTEGER NOT NULL,
    deletion_type TEXT NOT NULL CHECK (deletion_type IN ('hard_delete', 'anonymize', 'archive')),
    is_active BOOLEAN DEFAULT true,
    version INTEGER NOT NULL DEFAULT 1,
    last_modified_at TIMESTAMPTZ DEFAULT NOW(),
    last_modified_by UUID REFERENCES auth.users(id),
    notes TEXT,
    CONSTRAINT valid_retention_days CHECK (retention_days > 0 AND retention_days <= 1095)
);

-- Insert SSOT retention policies (hard-coded, immutable without version bump)
INSERT INTO public.retention_policies (domain, retention_days, deletion_type, notes) VALUES
    -- Learning & Assessment
    ('quiz_attempts_raw', 90, 'hard_delete', 'Raw quiz attempt data'),
    ('question_answers', 30, 'hard_delete', 'Individual question-level answers'),
    ('aggregated_scores', 730, 'archive', 'User performance aggregates'),
    ('best_scores', 36500, 'hard_delete', 'Best scores retained until account deletion'),
    ('streaks', 36500, 'hard_delete', 'Streak data retained until account deletion'),
    
    -- Economy & Abuse
    ('coin_ledger', 365, 'archive', 'Coin transaction history'),
    ('ad_watch_aggregates', 90, 'hard_delete', 'Ad viewing aggregates'),
    ('abuse_reports', 730, 'anonymize', 'Abuse and fraud flags'),
    ('admin_audit_log', 1095, 'archive', 'Admin action audit trail'),
    
    -- System Logs
    ('api_logs', 30, 'hard_delete', 'API request/response logs'),
    ('error_logs', 30, 'hard_delete', 'Application error logs'),
    ('security_events', 180, 'archive', 'Security-related events')
ON CONFLICT (domain) DO NOTHING;

-- PART 2: DELETION TRACKING
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.deletion_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    request_type TEXT NOT NULL CHECK (request_type IN ('partial', 'full')),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'cancelled')),
    requested_at TIMESTAMPTZ DEFAULT NOW(),
    scheduled_for TIMESTAMPTZ NOT NULL, -- 7-day grace period
    completed_at TIMESTAMPTZ,
    cancelled_at TIMESTAMPTZ,
    deletion_summary JSONB, -- What was deleted
    CONSTRAINT valid_schedule CHECK (scheduled_for > requested_at)
);

CREATE INDEX idx_deletion_requests_user ON public.deletion_requests(user_id);
CREATE INDEX idx_deletion_requests_status ON public.deletion_requests(status);
CREATE INDEX idx_deletion_requests_scheduled ON public.deletion_requests(scheduled_for) WHERE status = 'pending';

-- PART 3: INACTIVE ACCOUNT TRACKING
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.account_activity_tracker (
    user_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
    last_login_at TIMESTAMPTZ,
    last_quiz_at TIMESTAMPTZ,
    last_coin_activity_at TIMESTAMPTZ,
    inactivity_tier INTEGER DEFAULT 0, -- 0=active, 1=12mo, 2=24mo, 3=36mo
    next_purge_action TEXT,
    next_purge_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_activity_tracker_purge ON public.account_activity_tracker(next_purge_at) WHERE next_purge_at IS NOT NULL;

-- PART 4: ANONYMIZATION LOG
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.anonymization_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID, -- NULL after anonymization
    original_user_hash TEXT NOT NULL, -- One-way hash for audit
    anonymized_at TIMESTAMPTZ DEFAULT NOW(),
    tables_affected TEXT[] NOT NULL,
    records_affected INTEGER NOT NULL,
    retention_policy TEXT NOT NULL,
    CONSTRAINT valid_records CHECK (records_affected >= 0)
);

CREATE INDEX idx_anonymization_log_date ON public.anonymization_log(anonymized_at);

-- PART 5: RETENTION ENFORCEMENT FUNCTIONS
-- ============================================================================

-- Function: Mark user attempts for deletion based on retention policy
CREATE OR REPLACE FUNCTION public.mark_expired_attempts()
RETURNS TABLE(attempts_marked INTEGER) AS $$
DECLARE
    retention_days INTEGER;
    cutoff_date TIMESTAMPTZ;
BEGIN
    -- Get retention policy for quiz attempts
    SELECT rp.retention_days INTO retention_days
    FROM public.retention_policies rp
    WHERE rp.domain = 'quiz_attempts_raw' AND rp.is_active = true;
    
    cutoff_date := NOW() - (retention_days || ' days')::INTERVAL;
    
    -- Mark attempts for deletion (soft delete first)
    UPDATE public.user_attempts
    SET deleted_at = NOW()
    WHERE created_at < cutoff_date
      AND deleted_at IS NULL;
    
    GET DIAGNOSTICS attempts_marked = ROW_COUNT;
    RETURN QUERY SELECT attempts_marked;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Hard delete marked attempts
CREATE OR REPLACE FUNCTION public.purge_deleted_attempts()
RETURNS TABLE(attempts_purged INTEGER) AS $$
DECLARE
    purged_count INTEGER;
BEGIN
    -- Hard delete attempts marked for deletion > 7 days ago
    DELETE FROM public.user_attempts
    WHERE deleted_at IS NOT NULL
      AND deleted_at < NOW() - INTERVAL '7 days';
    
    GET DIAGNOSTICS purged_count = ROW_COUNT;
    RETURN QUERY SELECT purged_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Anonymize user answers
CREATE OR REPLACE FUNCTION public.anonymize_question_answers()
RETURNS TABLE(answers_anonymized INTEGER) AS $$
DECLARE
    retention_days INTEGER;
    cutoff_date TIMESTAMPTZ;
    affected_count INTEGER;
BEGIN
    SELECT rp.retention_days INTO retention_days
    FROM public.retention_policies rp
    WHERE rp.domain = 'question_answers' AND rp.is_active = true;
    
    cutoff_date := NOW() - (retention_days || ' days')::INTERVAL;
    
    -- Anonymize by removing user_id link
    UPDATE public.user_answers
    SET user_id = NULL,
        anonymized_at = NOW()
    WHERE created_at < cutoff_date
      AND anonymized_at IS NULL;
    
    GET DIAGNOSTICS affected_count = ROW_COUNT;
    RETURN QUERY SELECT affected_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Process inactive accounts
CREATE OR REPLACE FUNCTION public.process_inactive_accounts()
RETURNS TABLE(
    tier_1_processed INTEGER,
    tier_2_processed INTEGER,
    tier_3_processed INTEGER
) AS $$
DECLARE
    t1_count INTEGER := 0;
    t2_count INTEGER := 0;
    t3_count INTEGER := 0;
BEGIN
    -- Tier 1: 12 months inactive → purge raw attempts
    UPDATE public.account_activity_tracker
    SET inactivity_tier = 1,
        next_purge_action = 'purge_raw_attempts',
        next_purge_at = NOW() + INTERVAL '30 days'
    WHERE (last_login_at < NOW() - INTERVAL '12 months' OR last_login_at IS NULL)
      AND inactivity_tier = 0;
    
    GET DIAGNOSTICS t1_count = ROW_COUNT;
    
    -- Tier 2: 24 months inactive → anonymize aggregates
    UPDATE public.account_activity_tracker
    SET inactivity_tier = 2,
        next_purge_action = 'anonymize_aggregates',
        next_purge_at = NOW() + INTERVAL '30 days'
    WHERE (last_login_at < NOW() - INTERVAL '24 months' OR last_login_at IS NULL)
      AND inactivity_tier = 1;
    
    GET DIAGNOSTICS t2_count = ROW_COUNT;
    
    -- Tier 3: 36 months inactive → auto-delete account
    INSERT INTO public.deletion_requests (user_id, request_type, scheduled_for)
    SELECT user_id, 'full', NOW() + INTERVAL '7 days'
    FROM public.account_activity_tracker
    WHERE (last_login_at < NOW() - INTERVAL '36 months' OR last_login_at IS NULL)
      AND inactivity_tier = 2;
    
    GET DIAGNOSTICS t3_count = ROW_COUNT;
    
    RETURN QUERY SELECT t1_count, t2_count, t3_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Execute user deletion request
CREATE OR REPLACE FUNCTION public.execute_user_deletion(deletion_request_id UUID)
RETURNS JSONB AS $$
DECLARE
    req RECORD;
    deletion_summary JSONB;
    user_hash TEXT;
BEGIN
    -- Get deletion request
    SELECT * INTO req
    FROM public.deletion_requests
    WHERE id = deletion_request_id
      AND status = 'pending'
      AND scheduled_for <= NOW();
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Request not found or not ready');
    END IF;
    
    -- Update status
    UPDATE public.deletion_requests
    SET status = 'processing'
    WHERE id = deletion_request_id;
    
    -- Generate one-way hash for audit
    user_hash := encode(digest(req.user_id::TEXT, 'sha256'), 'hex');
    
    IF req.request_type = 'partial' THEN
        -- Partial deletion: anonymize learning history
        UPDATE public.user_attempts SET user_id = NULL WHERE user_id = req.user_id;
        UPDATE public.user_answers SET user_id = NULL WHERE user_id = req.user_id;
        
        deletion_summary := jsonb_build_object(
            'type', 'partial',
            'attempts_anonymized', (SELECT COUNT(*) FROM public.user_attempts WHERE user_id IS NULL),
            'answers_anonymized', (SELECT COUNT(*) FROM public.user_answers WHERE user_id IS NULL)
        );
        
    ELSIF req.request_type = 'full' THEN
        -- Full deletion: hard delete profile and cascade
        DELETE FROM public.profiles WHERE id = req.user_id;
        
        -- Anonymize logs (retain for legal basis)
        UPDATE public.admin_audit_log SET admin_user_id = NULL WHERE admin_user_id = req.user_id;
        
        deletion_summary := jsonb_build_object(
            'type', 'full',
            'profile_deleted', true,
            'cascade_completed', true
        );
    END IF;
    
    -- Log anonymization
    INSERT INTO public.anonymization_log (user_id, original_user_hash, tables_affected, records_affected, retention_policy)
    VALUES (NULL, user_hash, ARRAY['user_attempts', 'user_answers', 'profiles'], 1, req.request_type);
    
    -- Mark request as completed
    UPDATE public.deletion_requests
    SET status = 'completed',
        completed_at = NOW(),
        deletion_summary = deletion_summary
    WHERE id = deletion_request_id;
    
    RETURN jsonb_build_object('success', true, 'summary', deletion_summary);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 6: RLS POLICIES
-- ============================================================================

ALTER TABLE public.retention_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deletion_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_activity_tracker ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.anonymization_log ENABLE ROW LEVEL SECURITY;

-- Only super admins can view/modify retention policies
CREATE POLICY "Super admins manage retention policies"
    ON public.retention_policies
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid()
              AND role = 'super_admin'
        )
    );

-- Users can view their own deletion requests
CREATE POLICY "Users view own deletion requests"
    ON public.deletion_requests
    FOR SELECT
    USING (user_id = auth.uid());

-- Users can create deletion requests
CREATE POLICY "Users create deletion requests"
    ON public.deletion_requests
    FOR INSERT
    WITH CHECK (user_id = auth.uid());

-- Users can cancel pending deletion requests
CREATE POLICY "Users cancel own deletion requests"
    ON public.deletion_requests
    FOR UPDATE
    USING (user_id = auth.uid() AND status = 'pending')
    WITH CHECK (status = 'cancelled');

-- Ops/Super admins can view all deletion requests
CREATE POLICY "Admins view all deletion requests"
    ON public.deletion_requests
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid()
              AND role IN ('ops_admin', 'super_admin')
        )
    );

-- Only super admins can view anonymization log
CREATE POLICY "Super admins view anonymization log"
    ON public.anonymization_log
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid()
              AND role = 'super_admin'
        )
    );

-- PART 7: CRON JOBS (pg_cron extension required)
-- ============================================================================

-- Daily retention enforcement at 2 AM UTC
-- SELECT cron.schedule('retention-enforcement', '0 2 * * *', $$
--     SELECT public.mark_expired_attempts();
--     SELECT public.purge_deleted_attempts();
--     SELECT public.anonymize_question_answers();
--     SELECT public.process_inactive_accounts();
-- $$);

-- Process pending deletion requests every 6 hours
-- SELECT cron.schedule('process-deletions', '0 */6 * * *', $$
--     SELECT public.execute_user_deletion(id)
--     FROM public.deletion_requests
--     WHERE status = 'pending'
--       AND scheduled_for <= NOW()
--     LIMIT 100;
-- $$);

COMMENT ON TABLE public.retention_policies IS 'SSOT for all data retention policies. Version-controlled and immutable without approval.';
COMMENT ON TABLE public.deletion_requests IS 'User-initiated deletion requests with 7-day grace period.';
COMMENT ON TABLE public.account_activity_tracker IS 'Tracks user activity for inactive account purging.';
COMMENT ON TABLE public.anonymization_log IS 'Immutable log of all anonymization operations for compliance.';
