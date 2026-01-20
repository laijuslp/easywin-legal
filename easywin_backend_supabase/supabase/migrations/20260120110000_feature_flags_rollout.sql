-- ============================================================================
-- EASYWIN 1.0 - FEATURE FLAGS & ROLLOUT CONTROL
-- Safe feature deployment with kill switches and gradual rollout
-- ============================================================================

-- PART 1: FEATURE FLAGS
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.feature_flags (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    flag_key TEXT NOT NULL UNIQUE,
    flag_name TEXT NOT NULL,
    description TEXT NOT NULL,
    flag_type TEXT NOT NULL CHECK (flag_type IN ('boolean', 'percentage', 'user_list', 'ab_test')),
    
    -- Default state (OFF by default)
    is_enabled BOOLEAN DEFAULT false,
    rollout_percentage INTEGER DEFAULT 0 CHECK (rollout_percentage >= 0 AND rollout_percentage <= 100),
    
    -- Targeting
    enabled_user_ids UUID[] DEFAULT ARRAY[]::UUID[],
    enabled_roles TEXT[] DEFAULT ARRAY[]::TEXT[],
    platform_filter TEXT[] DEFAULT ARRAY[]::TEXT[], -- 'android', 'ios', 'web'
    
    -- Kill switch
    has_kill_switch BOOLEAN DEFAULT true,
    kill_switch_activated BOOLEAN DEFAULT false,
    kill_switch_reason TEXT,
    kill_switch_activated_at TIMESTAMPTZ,
    kill_switch_activated_by UUID REFERENCES auth.users(id),
    
    -- Metadata
    created_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID REFERENCES auth.users(id),
    last_modified_at TIMESTAMPTZ DEFAULT NOW(),
    last_modified_by UUID REFERENCES auth.users(id),
    
    -- Rollout tracking
    rollout_started_at TIMESTAMPTZ,
    rollout_completed_at TIMESTAMPTZ,
    rollout_phase TEXT CHECK (rollout_phase IN ('internal', 'canary', '25_percent', '100_percent', 'completed'))
);

CREATE INDEX idx_feature_flags_enabled ON public.feature_flags(is_enabled) WHERE is_enabled = true;
CREATE INDEX idx_feature_flags_rollout ON public.feature_flags(rollout_phase) WHERE rollout_phase IS NOT NULL;

-- PART 2: ROLLOUT SCHEDULE
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.rollout_schedule (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    flag_key TEXT NOT NULL REFERENCES public.feature_flags(flag_key) ON DELETE CASCADE,
    phase TEXT NOT NULL CHECK (phase IN ('internal', 'canary', '25_percent', '100_percent')),
    scheduled_at TIMESTAMPTZ NOT NULL,
    target_percentage INTEGER NOT NULL CHECK (target_percentage >= 0 AND target_percentage <= 100),
    executed_at TIMESTAMPTZ,
    execution_status TEXT CHECK (execution_status IN ('pending', 'executed', 'failed', 'cancelled')),
    failure_reason TEXT,
    
    CONSTRAINT unique_flag_phase UNIQUE(flag_key, phase)
);

CREATE INDEX idx_rollout_schedule_pending ON public.rollout_schedule(scheduled_at) WHERE execution_status = 'pending';

-- PART 3: FEATURE FLAG EVALUATION LOG
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.flag_evaluation_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    flag_key TEXT NOT NULL,
    user_id UUID,
    evaluated_at TIMESTAMPTZ DEFAULT NOW(),
    was_enabled BOOLEAN NOT NULL,
    evaluation_reason TEXT NOT NULL, -- 'kill_switch', 'percentage', 'user_list', 'disabled'
    platform TEXT,
    app_version TEXT,
    
    -- Retention: 30 days
    expires_at TIMESTAMPTZ DEFAULT (NOW() + INTERVAL '30 days')
);

CREATE INDEX idx_flag_evaluation_log_flag ON public.flag_evaluation_log(flag_key, evaluated_at DESC);
CREATE INDEX idx_flag_evaluation_log_expires ON public.flag_evaluation_log(expires_at) WHERE expires_at <= NOW();

-- PART 4: FEATURE FLAG FUNCTIONS
-- ============================================================================

-- Function: Evaluate feature flag for user
CREATE OR REPLACE FUNCTION public.is_feature_enabled(
    p_flag_key TEXT,
    p_user_id UUID DEFAULT auth.uid(),
    p_platform TEXT DEFAULT 'android'
)
RETURNS BOOLEAN AS $$
DECLARE
    flag RECORD;
    user_hash INTEGER;
    is_enabled BOOLEAN := false;
    reason TEXT;
BEGIN
    -- Get flag
    SELECT * INTO flag
    FROM public.feature_flags
    WHERE flag_key = p_flag_key;
    
    IF NOT FOUND THEN
        RETURN false;
    END IF;
    
    -- Check kill switch
    IF flag.kill_switch_activated THEN
        reason := 'kill_switch';
        is_enabled := false;
    -- Check if globally disabled
    ELSIF NOT flag.is_enabled THEN
        reason := 'disabled';
        is_enabled := false;
    -- Check user list
    ELSIF p_user_id = ANY(flag.enabled_user_ids) THEN
        reason := 'user_list';
        is_enabled := true;
    -- Check role
    ELSIF EXISTS (
        SELECT 1 FROM public.user_roles
        WHERE user_id = p_user_id
          AND role = ANY(flag.enabled_roles)
    ) THEN
        reason := 'role_match';
        is_enabled := true;
    -- Check percentage rollout
    ELSIF flag.rollout_percentage > 0 THEN
        -- Consistent hashing for stable rollout
        user_hash := abs(hashtext(p_user_id::TEXT || p_flag_key)) % 100;
        is_enabled := user_hash < flag.rollout_percentage;
        reason := 'percentage_' || flag.rollout_percentage::TEXT;
    ELSE
        reason := 'not_in_rollout';
        is_enabled := false;
    END IF;
    
    -- Log evaluation (async, don't block)
    BEGIN
        INSERT INTO public.flag_evaluation_log (
            flag_key, user_id, was_enabled, evaluation_reason, platform
        ) VALUES (
            p_flag_key, p_user_id, is_enabled, reason, p_platform
        );
    EXCEPTION
        WHEN OTHERS THEN
            -- Ignore logging errors
            NULL;
    END;
    
    RETURN is_enabled;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Activate kill switch
CREATE OR REPLACE FUNCTION public.activate_kill_switch(
    p_flag_key TEXT,
    p_reason TEXT
)
RETURNS JSONB AS $$
BEGIN
    UPDATE public.feature_flags
    SET kill_switch_activated = true,
        kill_switch_reason = p_reason,
        kill_switch_activated_at = NOW(),
        kill_switch_activated_by = auth.uid(),
        is_enabled = false
    WHERE flag_key = p_flag_key
      AND has_kill_switch = true;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Flag not found or kill switch not available');
    END IF;
    
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Kill switch activated',
        'flag_key', p_flag_key,
        'reason', p_reason
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Deactivate kill switch
CREATE OR REPLACE FUNCTION public.deactivate_kill_switch(p_flag_key TEXT)
RETURNS JSONB AS $$
BEGIN
    UPDATE public.feature_flags
    SET kill_switch_activated = false,
        kill_switch_reason = NULL
    WHERE flag_key = p_flag_key;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Flag not found');
    END IF;
    
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Kill switch deactivated',
        'flag_key', p_flag_key
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Update rollout percentage
CREATE OR REPLACE FUNCTION public.update_rollout_percentage(
    p_flag_key TEXT,
    p_percentage INTEGER
)
RETURNS JSONB AS $$
BEGIN
    IF p_percentage < 0 OR p_percentage > 100 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid percentage');
    END IF;
    
    UPDATE public.feature_flags
    SET rollout_percentage = p_percentage,
        last_modified_at = NOW(),
        last_modified_by = auth.uid()
    WHERE flag_key = p_flag_key;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Flag not found');
    END IF;
    
    RETURN jsonb_build_object(
        'success', true,
        'flag_key', p_flag_key,
        'rollout_percentage', p_percentage
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Execute scheduled rollout
CREATE OR REPLACE FUNCTION public.execute_scheduled_rollouts()
RETURNS TABLE(executed_count INTEGER) AS $$
DECLARE
    schedule RECORD;
    exec_count INTEGER := 0;
BEGIN
    FOR schedule IN 
        SELECT * FROM public.rollout_schedule
        WHERE execution_status = 'pending'
          AND scheduled_at <= NOW()
        ORDER BY scheduled_at
    LOOP
        BEGIN
            -- Update flag
            UPDATE public.feature_flags
            SET rollout_percentage = schedule.target_percentage,
                rollout_phase = schedule.phase,
                is_enabled = true
            WHERE flag_key = schedule.flag_key;
            
            -- Mark as executed
            UPDATE public.rollout_schedule
            SET execution_status = 'executed',
                executed_at = NOW()
            WHERE id = schedule.id;
            
            exec_count := exec_count + 1;
        EXCEPTION
            WHEN OTHERS THEN
                UPDATE public.rollout_schedule
                SET execution_status = 'failed',
                    failure_reason = SQLERRM
                WHERE id = schedule.id;
        END;
    END LOOP;
    
    RETURN QUERY SELECT exec_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 5: ROLLOUT TEMPLATES
-- ============================================================================

-- Function: Create standard rollout schedule
CREATE OR REPLACE FUNCTION public.create_rollout_schedule(
    p_flag_key TEXT,
    p_start_date TIMESTAMPTZ DEFAULT NOW()
)
RETURNS JSONB AS $$
BEGIN
    -- Internal admins (24-48h)
    INSERT INTO public.rollout_schedule (flag_key, phase, scheduled_at, target_percentage)
    VALUES (p_flag_key, 'internal', p_start_date, 0);
    
    -- Canary 1-5% (after 48h)
    INSERT INTO public.rollout_schedule (flag_key, phase, scheduled_at, target_percentage)
    VALUES (p_flag_key, 'canary', p_start_date + INTERVAL '48 hours', 5);
    
    -- 25% (after 72h if canary successful)
    INSERT INTO public.rollout_schedule (flag_key, phase, scheduled_at, target_percentage)
    VALUES (p_flag_key, '25_percent', p_start_date + INTERVAL '72 hours', 25);
    
    -- 100% (after 96h if 25% successful)
    INSERT INTO public.rollout_schedule (flag_key, phase, scheduled_at, target_percentage)
    VALUES (p_flag_key, '100_percent', p_start_date + INTERVAL '96 hours', 100);
    
    RETURN jsonb_build_object(
        'success', true,
        'flag_key', p_flag_key,
        'phases', ARRAY['internal', 'canary', '25_percent', '100_percent'],
        'start_date', p_start_date
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 6: RLS POLICIES
-- ============================================================================

ALTER TABLE public.feature_flags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rollout_schedule ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.flag_evaluation_log ENABLE ROW LEVEL SECURITY;

-- All authenticated users can read feature flags
CREATE POLICY "All users read feature flags"
    ON public.feature_flags FOR SELECT
    USING (true);

-- Only ops/super admins can modify feature flags
CREATE POLICY "Admins manage feature flags"
    ON public.feature_flags FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid()
              AND role IN ('ops_admin', 'super_admin')
        )
    );

-- Admins can view rollout schedule
CREATE POLICY "Admins view rollout schedule"
    ON public.rollout_schedule FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid()
              AND role IN ('ops_admin', 'super_admin')
        )
    );

-- Users can view their own flag evaluations
CREATE POLICY "Users view own flag evaluations"
    ON public.flag_evaluation_log FOR SELECT
    USING (user_id = auth.uid());

-- Admins can view all flag evaluations
CREATE POLICY "Admins view all flag evaluations"
    ON public.flag_evaluation_log FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid()
              AND role IN ('ops_admin', 'super_admin')
        )
    );

-- PART 7: CRON JOBS
-- ============================================================================

-- Execute scheduled rollouts every hour
-- SELECT cron.schedule('execute-rollouts', '0 * * * *', $$
--     SELECT public.execute_scheduled_rollouts();
-- $$);

-- Purge old evaluation logs daily
-- SELECT cron.schedule('purge-flag-evaluations', '0 5 * * *', $$
--     DELETE FROM public.flag_evaluation_log WHERE expires_at <= NOW();
-- $$);

COMMENT ON TABLE public.feature_flags IS 'Feature flags with kill switches and gradual rollout support.';
COMMENT ON TABLE public.rollout_schedule IS 'Automated rollout schedule for feature flags.';
COMMENT ON TABLE public.flag_evaluation_log IS 'Audit log of feature flag evaluations (30-day retention).';
COMMENT ON FUNCTION public.is_feature_enabled IS 'Evaluate feature flag for user with consistent hashing.';
COMMENT ON FUNCTION public.activate_kill_switch IS 'Instantly disable a feature flag (emergency use).';
