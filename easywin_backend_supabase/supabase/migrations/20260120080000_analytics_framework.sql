-- ============================================================================
-- EASYWIN 1.0 - METRICS & ANALYTICS FRAMEWORK (PRIVACY-FIRST)
-- Safe-by-design analytics with explicit allowlists and forbidden identifiers
-- ============================================================================

-- PART 1: ALLOWED EVENTS (EXPLICIT ALLOWLIST)
-- ============================================================================

CREATE TYPE public.analytics_event_type AS ENUM (
    -- Quiz Lifecycle
    'quiz_started',
    'quiz_completed',
    'quiz_abandoned',
    
    -- Question Interaction
    'question_seen',
    'question_answered',
    'question_skipped',
    'question_timed_out',
    
    -- Retry Behavior
    'retry_attempted',
    
    -- Economy
    'coins_earned',
    'coins_spent'
);

-- PART 2: RAW ANALYTICS EVENTS (90-DAY RETENTION)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.analytics_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Allowed Identifiers ONLY
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    session_id UUID NOT NULL,
    device_hash TEXT, -- Rotating hash, no GAID/IDFA
    
    -- Event Data
    event_type public.analytics_event_type NOT NULL,
    event_timestamp TIMESTAMPTZ DEFAULT NOW(),
    
    -- Context (Quiz/Question)
    quiz_id UUID REFERENCES public.assessments(id) ON DELETE SET NULL,
    question_id UUID REFERENCES public.questions(id) ON DELETE SET NULL,
    
    -- Metrics (Aggregatable Only)
    retry_count INTEGER DEFAULT 0,
    correctness_on_retry BOOLEAN,
    time_spent_seconds INTEGER, -- Quiz-level only, not question-level
    coins_amount INTEGER, -- For coin events
    
    -- Metadata
    app_version TEXT,
    platform TEXT CHECK (platform IN ('android', 'ios', 'web')),
    
    -- Retention
    created_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ DEFAULT (NOW() + INTERVAL '90 days'),
    
    CONSTRAINT valid_time_spent CHECK (time_spent_seconds IS NULL OR time_spent_seconds >= 0),
    CONSTRAINT valid_coins CHECK (coins_amount IS NULL OR coins_amount >= 0)
);

-- Indexes for query performance
CREATE INDEX idx_analytics_events_user ON public.analytics_events(user_id, event_timestamp DESC);
CREATE INDEX idx_analytics_events_type ON public.analytics_events(event_type, event_timestamp DESC);
CREATE INDEX idx_analytics_events_expires ON public.analytics_events(expires_at) WHERE expires_at <= NOW();
CREATE INDEX idx_analytics_events_session ON public.analytics_events(session_id);

-- PART 3: AGGREGATED METRICS (24-MONTH RETENTION)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.analytics_aggregates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Aggregation Period
    period_start TIMESTAMPTZ NOT NULL,
    period_end TIMESTAMPTZ NOT NULL,
    granularity TEXT NOT NULL CHECK (granularity IN ('hourly', 'daily', 'weekly', 'monthly')),
    
    -- Dimensions (No PII)
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE, -- Nullable for global aggregates
    quiz_id UUID REFERENCES public.assessments(id) ON DELETE SET NULL,
    platform TEXT,
    
    -- Metrics
    quiz_starts INTEGER DEFAULT 0,
    quiz_completions INTEGER DEFAULT 0,
    quiz_abandons INTEGER DEFAULT 0,
    
    questions_seen INTEGER DEFAULT 0,
    questions_answered INTEGER DEFAULT 0,
    questions_correct INTEGER DEFAULT 0,
    questions_skipped INTEGER DEFAULT 0,
    questions_timed_out INTEGER DEFAULT 0,
    
    retry_count_total INTEGER DEFAULT 0,
    retry_success_count INTEGER DEFAULT 0,
    
    avg_time_spent_seconds NUMERIC(10,2),
    
    coins_earned_total INTEGER DEFAULT 0,
    coins_spent_total INTEGER DEFAULT 0,
    
    -- Retention
    created_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ DEFAULT (NOW() + INTERVAL '24 months'),
    
    CONSTRAINT valid_period CHECK (period_end > period_start),
    CONSTRAINT valid_metrics CHECK (
        quiz_starts >= 0 AND
        quiz_completions >= 0 AND
        questions_answered >= 0
    )
);

CREATE INDEX idx_analytics_aggregates_period ON public.analytics_aggregates(period_start, period_end);
CREATE INDEX idx_analytics_aggregates_user ON public.analytics_aggregates(user_id, period_start DESC);
CREATE INDEX idx_analytics_aggregates_expires ON public.analytics_aggregates(expires_at) WHERE expires_at <= NOW();

-- PART 4: FORBIDDEN DATA ENFORCEMENT
-- ============================================================================

-- Table to track forbidden identifier attempts (security monitoring)
CREATE TABLE IF NOT EXISTS public.analytics_violations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    attempted_identifier TEXT NOT NULL,
    identifier_type TEXT NOT NULL, -- 'email', 'phone', 'gaid', 'idfa', 'ip', 'gps'
    attempted_at TIMESTAMPTZ DEFAULT NOW(),
    source_function TEXT,
    blocked BOOLEAN DEFAULT true,
    admin_notified BOOLEAN DEFAULT false
);

CREATE INDEX idx_analytics_violations_date ON public.analytics_violations(attempted_at DESC);

-- Function: Validate event data (no forbidden identifiers)
CREATE OR REPLACE FUNCTION public.validate_analytics_event()
RETURNS TRIGGER AS $$
BEGIN
    -- Ensure no forbidden fields are present in metadata
    IF NEW.device_hash ~* '(gaid|idfa|advertising|adid)' THEN
        INSERT INTO public.analytics_violations (attempted_identifier, identifier_type, source_function)
        VALUES (NEW.device_hash, 'advertising_id', 'validate_analytics_event');
        
        RAISE EXCEPTION 'Forbidden advertising identifier detected';
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER validate_analytics_event_trigger
    BEFORE INSERT ON public.analytics_events
    FOR EACH ROW
    EXECUTE FUNCTION public.validate_analytics_event();

-- PART 5: AGGREGATION FUNCTIONS
-- ============================================================================

-- Function: Aggregate raw events into daily metrics
CREATE OR REPLACE FUNCTION public.aggregate_daily_analytics(target_date DATE DEFAULT CURRENT_DATE - 1)
RETURNS TABLE(aggregates_created INTEGER) AS $$
DECLARE
    period_start TIMESTAMPTZ;
    period_end TIMESTAMPTZ;
    agg_count INTEGER;
BEGIN
    period_start := target_date::TIMESTAMPTZ;
    period_end := (target_date + 1)::TIMESTAMPTZ;
    
    -- Aggregate by user
    INSERT INTO public.analytics_aggregates (
        period_start,
        period_end,
        granularity,
        user_id,
        platform,
        quiz_starts,
        quiz_completions,
        quiz_abandons,
        questions_seen,
        questions_answered,
        questions_correct,
        questions_skipped,
        questions_timed_out,
        retry_count_total,
        retry_success_count,
        avg_time_spent_seconds,
        coins_earned_total,
        coins_spent_total
    )
    SELECT
        period_start,
        period_end,
        'daily',
        user_id,
        platform,
        COUNT(*) FILTER (WHERE event_type = 'quiz_started'),
        COUNT(*) FILTER (WHERE event_type = 'quiz_completed'),
        COUNT(*) FILTER (WHERE event_type = 'quiz_abandoned'),
        COUNT(*) FILTER (WHERE event_type = 'question_seen'),
        COUNT(*) FILTER (WHERE event_type = 'question_answered'),
        COUNT(*) FILTER (WHERE event_type = 'question_answered' AND correctness_on_retry = true),
        COUNT(*) FILTER (WHERE event_type = 'question_skipped'),
        COUNT(*) FILTER (WHERE event_type = 'question_timed_out'),
        SUM(retry_count) FILTER (WHERE event_type = 'retry_attempted'),
        COUNT(*) FILTER (WHERE event_type = 'retry_attempted' AND correctness_on_retry = true),
        AVG(time_spent_seconds) FILTER (WHERE event_type = 'quiz_completed'),
        SUM(coins_amount) FILTER (WHERE event_type = 'coins_earned'),
        SUM(coins_amount) FILTER (WHERE event_type = 'coins_spent')
    FROM public.analytics_events
    WHERE event_timestamp >= period_start
      AND event_timestamp < period_end
    GROUP BY user_id, platform;
    
    GET DIAGNOSTICS agg_count = ROW_COUNT;
    RETURN QUERY SELECT agg_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Purge expired raw events (90-day retention)
CREATE OR REPLACE FUNCTION public.purge_expired_analytics()
RETURNS TABLE(events_purged INTEGER) AS $$
DECLARE
    purged_count INTEGER;
BEGIN
    DELETE FROM public.analytics_events
    WHERE expires_at <= NOW();
    
    GET DIAGNOSTICS purged_count = ROW_COUNT;
    RETURN QUERY SELECT purged_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Purge expired aggregates (24-month retention)
CREATE OR REPLACE FUNCTION public.purge_expired_aggregates()
RETURNS TABLE(aggregates_purged INTEGER) AS $$
DECLARE
    purged_count INTEGER;
BEGIN
    DELETE FROM public.analytics_aggregates
    WHERE expires_at <= NOW();
    
    GET DIAGNOSTICS purged_count = ROW_COUNT;
    RETURN QUERY SELECT purged_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 6: ANALYTICS RPC (CLIENT-FACING)
-- ============================================================================

-- RPC: Track analytics event (with validation)
CREATE OR REPLACE FUNCTION public.track_analytics_event(
    p_event_type TEXT,
    p_session_id UUID,
    p_quiz_id UUID DEFAULT NULL,
    p_question_id UUID DEFAULT NULL,
    p_retry_count INTEGER DEFAULT 0,
    p_correctness_on_retry BOOLEAN DEFAULT NULL,
    p_time_spent_seconds INTEGER DEFAULT NULL,
    p_coins_amount INTEGER DEFAULT NULL,
    p_platform TEXT DEFAULT 'android'
)
RETURNS JSONB AS $$
DECLARE
    event_id UUID;
BEGIN
    -- Validate event type
    IF p_event_type NOT IN (
        'quiz_started', 'quiz_completed', 'quiz_abandoned',
        'question_seen', 'question_answered', 'question_skipped', 'question_timed_out',
        'retry_attempted', 'coins_earned', 'coins_spent'
    ) THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid event type');
    END IF;
    
    -- Insert event
    INSERT INTO public.analytics_events (
        user_id,
        session_id,
        event_type,
        quiz_id,
        question_id,
        retry_count,
        correctness_on_retry,
        time_spent_seconds,
        coins_amount,
        platform
    ) VALUES (
        auth.uid(),
        p_session_id,
        p_event_type::public.analytics_event_type,
        p_quiz_id,
        p_question_id,
        p_retry_count,
        p_correctness_on_retry,
        p_time_spent_seconds,
        p_coins_amount,
        p_platform
    ) RETURNING id INTO event_id;
    
    RETURN jsonb_build_object('success', true, 'event_id', event_id);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 7: RLS POLICIES
-- ============================================================================

ALTER TABLE public.analytics_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.analytics_aggregates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.analytics_violations ENABLE ROW LEVEL SECURITY;

-- Users can only insert their own events (via RPC)
CREATE POLICY "Users insert own analytics events"
    ON public.analytics_events
    FOR INSERT
    WITH CHECK (user_id = auth.uid());

-- Users can view their own events
CREATE POLICY "Users view own analytics events"
    ON public.analytics_events
    FOR SELECT
    USING (user_id = auth.uid());

-- Users can view their own aggregates
CREATE POLICY "Users view own aggregates"
    ON public.analytics_aggregates
    FOR SELECT
    USING (user_id = auth.uid());

-- Ops/Super admins can view all aggregates (no raw events)
CREATE POLICY "Admins view all aggregates"
    ON public.analytics_aggregates
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid()
              AND role IN ('ops_admin', 'super_admin')
        )
    );

-- Only super admins can view violations
CREATE POLICY "Super admins view violations"
    ON public.analytics_violations
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid()
              AND role = 'super_admin'
        )
    );

-- PART 8: CRON JOBS
-- ============================================================================

-- Daily aggregation at 3 AM UTC
-- SELECT cron.schedule('analytics-aggregation', '0 3 * * *', $$
--     SELECT public.aggregate_daily_analytics();
-- $$);

-- Purge expired events daily at 4 AM UTC
-- SELECT cron.schedule('analytics-purge', '0 4 * * *', $$
--     SELECT public.purge_expired_analytics();
--     SELECT public.purge_expired_aggregates();
-- $$);

COMMENT ON TABLE public.analytics_events IS 'Privacy-first analytics with 90-day retention. No PII, no advertising IDs.';
COMMENT ON TABLE public.analytics_aggregates IS 'Aggregated metrics with 24-month retention. Safe for reporting.';
COMMENT ON TABLE public.analytics_violations IS 'Security log for forbidden identifier attempts.';
COMMENT ON FUNCTION public.track_analytics_event IS 'Client-facing RPC for tracking allowed events only.';
