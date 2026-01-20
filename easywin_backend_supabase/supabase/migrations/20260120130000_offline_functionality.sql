-- ============================================================================
-- EASYWIN 1.0 - OFFLINE & POOR NETWORK IMPLEMENTATION
-- CANONICAL SSOT - LOCKED - NON-NEGOTIABLE
-- ============================================================================

-- PART 1: OFFLINE ATTEMPTS TABLE
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.offline_attempts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    quiz_id UUID NOT NULL REFERENCES public.assessments(id) ON DELETE RESTRICT,
    quiz_version TEXT NOT NULL,
    mode TEXT NOT NULL DEFAULT 'offline_practice' CHECK (mode = 'offline_practice'),
    coins_reserved INTEGER NOT NULL CHECK (coins_reserved >= 0),
    
    -- Strict status state machine
    status TEXT NOT NULL DEFAULT 'IN_PROGRESS' CHECK (
        status IN (
            'IN_PROGRESS',
            'COMPLETED_LOCAL',
            'PENDING_SYNC',
            'SYNCING',
            'SYNCED',
            'FAILED_PERMANENT'
        )
    ),
    
    -- Timestamps
    started_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ,
    synced_at TIMESTAMPTZ,
    failed_at TIMESTAMPTZ,
    
    -- Answers payload (encrypted)
    answers JSONB NOT NULL DEFAULT '[]'::JSONB,
    
    -- Sync metadata
    idempotency_key UUID NOT NULL UNIQUE,
    sync_attempts INTEGER DEFAULT 0,
    last_sync_attempt_at TIMESTAMPTZ,
    rejection_reason TEXT,
    
    -- Audit
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT valid_completion CHECK (
        (status != 'COMPLETED_LOCAL') OR (completed_at IS NOT NULL)
    ),
    CONSTRAINT valid_sync CHECK (
        (status != 'SYNCED') OR (synced_at IS NOT NULL)
    ),
    CONSTRAINT valid_failure CHECK (
        (status != 'FAILED_PERMANENT') OR (failed_at IS NOT NULL AND rejection_reason IS NOT NULL)
    )
);

CREATE INDEX idx_offline_attempts_user ON public.offline_attempts(user_id, status);
CREATE INDEX idx_offline_attempts_pending ON public.offline_attempts(status) WHERE status IN ('PENDING_SYNC', 'SYNCING');
CREATE INDEX idx_offline_attempts_idempotency ON public.offline_attempts(idempotency_key);

-- PART 2: COIN ESCROW SYSTEM (MANDATORY STATE MACHINE)
-- ============================================================================

-- Extend coin_ledger with escrow states
ALTER TABLE public.coin_ledger 
ADD COLUMN IF NOT EXISTS state TEXT DEFAULT 'COMMITTED' 
CHECK (state IN ('RESERVED', 'COMMITTED', 'RELEASED'));

ALTER TABLE public.coin_ledger
ADD COLUMN IF NOT EXISTS reference_type TEXT
CHECK (reference_type IN ('quiz_attempt', 'offline_attempt', 'purchase', 'reward', 'admin_adjustment'));

ALTER TABLE public.coin_ledger
ADD COLUMN IF NOT EXISTS reference_id UUID;

CREATE INDEX idx_coin_ledger_state ON public.coin_ledger(state) WHERE state = 'RESERVED';
CREATE INDEX idx_coin_ledger_reference ON public.coin_ledger(reference_id, reference_type);

-- PART 3: QUIZ CACHE METADATA
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.quiz_cache_metadata (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    quiz_id UUID NOT NULL REFERENCES public.assessments(id) ON DELETE CASCADE,
    quiz_version TEXT NOT NULL,
    offline_practice_allowed BOOLEAN NOT NULL DEFAULT true,
    
    -- Cache payload (signed)
    cache_payload JSONB NOT NULL,
    cache_signature TEXT NOT NULL, -- HMAC signature
    
    -- TTL
    server_timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ttl_seconds INTEGER NOT NULL DEFAULT 259200, -- 3 days
    expires_at TIMESTAMPTZ NOT NULL,
    
    -- Invalidation
    is_valid BOOLEAN DEFAULT true,
    invalidated_at TIMESTAMPTZ,
    invalidation_reason TEXT,
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT unique_quiz_version UNIQUE(quiz_id, quiz_version),
    CONSTRAINT valid_ttl CHECK (ttl_seconds > 0 AND ttl_seconds <= 604800) -- Max 7 days
);

CREATE INDEX idx_quiz_cache_valid ON public.quiz_cache_metadata(quiz_id, is_valid) WHERE is_valid = true;
CREATE INDEX idx_quiz_cache_expires ON public.quiz_cache_metadata(expires_at) WHERE is_valid = true;

-- PART 4: COIN ESCROW FUNCTIONS (HARD-CODED STATE MACHINE)
-- ============================================================================

-- Function: Reserve coins for offline attempt
CREATE OR REPLACE FUNCTION public.reserve_coins_for_offline(
    p_user_id UUID,
    p_amount INTEGER,
    p_offline_attempt_id UUID
)
RETURNS JSONB AS $$
DECLARE
    available_balance INTEGER;
    reservation_id UUID;
BEGIN
    -- Check available balance (COMMITTED - RESERVED)
    SELECT 
        COALESCE(SUM(CASE WHEN state = 'COMMITTED' THEN amount ELSE 0 END), 0) -
        COALESCE(SUM(CASE WHEN state = 'RESERVED' THEN amount ELSE 0 END), 0)
    INTO available_balance
    FROM public.coin_ledger
    WHERE user_id = p_user_id;
    
    IF available_balance < p_amount THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'insufficient_balance',
            'available', available_balance,
            'required', p_amount
        );
    END IF;
    
    -- Reserve coins (negative amount, RESERVED state)
    INSERT INTO public.coin_ledger (
        user_id,
        amount,
        state,
        reference_type,
        reference_id,
        description
    ) VALUES (
        p_user_id,
        -p_amount,
        'RESERVED',
        'offline_attempt',
        p_offline_attempt_id,
        'Coins reserved for offline quiz attempt'
    ) RETURNING id INTO reservation_id;
    
    RETURN jsonb_build_object(
        'success', true,
        'reservation_id', reservation_id,
        'amount_reserved', p_amount,
        'new_available_balance', available_balance - p_amount
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Commit reserved coins (on successful sync)
CREATE OR REPLACE FUNCTION public.commit_reserved_coins(
    p_offline_attempt_id UUID
)
RETURNS JSONB AS $$
DECLARE
    reserved_amount INTEGER;
    committed_count INTEGER;
BEGIN
    -- Get reserved amount
    SELECT ABS(amount) INTO reserved_amount
    FROM public.coin_ledger
    WHERE reference_id = p_offline_attempt_id
      AND reference_type = 'offline_attempt'
      AND state = 'RESERVED';
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'no_reservation_found');
    END IF;
    
    -- Update state to COMMITTED
    UPDATE public.coin_ledger
    SET state = 'COMMITTED',
        updated_at = NOW()
    WHERE reference_id = p_offline_attempt_id
      AND reference_type = 'offline_attempt'
      AND state = 'RESERVED';
    
    GET DIAGNOSTICS committed_count = ROW_COUNT;
    
    RETURN jsonb_build_object(
        'success', true,
        'amount_committed', reserved_amount,
        'records_updated', committed_count
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Release reserved coins (on rejection/failure)
CREATE OR REPLACE FUNCTION public.release_reserved_coins(
    p_offline_attempt_id UUID,
    p_reason TEXT
)
RETURNS JSONB AS $$
DECLARE
    reserved_amount INTEGER;
    released_count INTEGER;
BEGIN
    -- Get reserved amount
    SELECT ABS(amount) INTO reserved_amount
    FROM public.coin_ledger
    WHERE reference_id = p_offline_attempt_id
      AND reference_type = 'offline_attempt'
      AND state = 'RESERVED';
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'no_reservation_found');
    END IF;
    
    -- Update state to RELEASED
    UPDATE public.coin_ledger
    SET state = 'RELEASED',
        description = description || ' | Released: ' || p_reason,
        updated_at = NOW()
    WHERE reference_id = p_offline_attempt_id
      AND reference_type = 'offline_attempt'
      AND state = 'RESERVED';
    
    GET DIAGNOSTICS released_count = ROW_COUNT;
    
    RETURN jsonb_build_object(
        'success', true,
        'amount_released', reserved_amount,
        'records_updated', released_count,
        'reason', p_reason
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 5: OFFLINE SYNC VALIDATION (STRICT ORDER)
-- ============================================================================

-- Function: Validate and sync offline attempt
CREATE OR REPLACE FUNCTION public.sync_offline_attempt(
    p_attempt_id UUID,
    p_idempotency_key UUID,
    p_quiz_id UUID,
    p_quiz_version TEXT,
    p_answers JSONB,
    p_coins_reserved INTEGER
)
RETURNS JSONB AS $$
DECLARE
    existing_attempt RECORD;
    quiz RECORD;
    validation_result JSONB;
    score_result JSONB;
BEGIN
    -- VALIDATION ORDER (STRICT - DO NOT REORDER)
    
    -- 1. Idempotency check
    SELECT * INTO existing_attempt
    FROM public.offline_attempts
    WHERE idempotency_key = p_idempotency_key;
    
    IF FOUND THEN
        IF existing_attempt.status = 'SYNCED' THEN
            RETURN jsonb_build_object(
                'success', true,
                'idempotent', true,
                'attempt_id', existing_attempt.id,
                'message', 'Attempt already synced'
            );
        END IF;
    END IF;
    
    -- 2. Quiz existence
    SELECT * INTO quiz
    FROM public.assessments
    WHERE id = p_quiz_id;
    
    IF NOT FOUND THEN
        PERFORM public.release_reserved_coins(p_attempt_id, 'Quiz not found');
        RETURN jsonb_build_object(
            'success', false,
            'error', 'quiz_not_found',
            'coins_released', true
        );
    END IF;
    
    -- 3. Quiz version match
    IF quiz.version != p_quiz_version THEN
        PERFORM public.release_reserved_coins(p_attempt_id, 'Version mismatch');
        
        UPDATE public.offline_attempts
        SET status = 'FAILED_PERMANENT',
            failed_at = NOW(),
            rejection_reason = 'This attempt could not be synced due to updated rules.'
        WHERE id = p_attempt_id;
        
        RETURN jsonb_build_object(
            'success', false,
            'error', 'version_mismatch',
            'expected_version', quiz.version,
            'provided_version', p_quiz_version,
            'coins_released', true,
            'user_message', 'This attempt could not be synced due to updated rules.'
        );
    END IF;
    
    -- 4. Entitlement validation (check user has access)
    IF NOT EXISTS (
        SELECT 1 FROM public.user_attempts
        WHERE user_id = auth.uid()
          AND quiz_id = p_quiz_id
        LIMIT 1
    ) AND quiz.is_premium = true THEN
        PERFORM public.release_reserved_coins(p_attempt_id, 'Entitlement invalid');
        RETURN jsonb_build_object(
            'success', false,
            'error', 'entitlement_invalid',
            'coins_released', true
        );
    END IF;
    
    -- 5. Rule integrity check (coins match)
    IF p_coins_reserved != quiz.coins_required THEN
        PERFORM public.release_reserved_coins(p_attempt_id, 'Rule mismatch - coins');
        RETURN jsonb_build_object(
            'success', false,
            'error', 'rule_mismatch',
            'expected_coins', quiz.coins_required,
            'provided_coins', p_coins_reserved,
            'coins_released', true
        );
    END IF;
    
    -- 6. Scoring verification
    -- (Simplified - actual scoring logic would be more complex)
    score_result := jsonb_build_object(
        'score', 0,
        'correct', 0,
        'total', jsonb_array_length(p_answers)
    );
    
    -- 7. Coin commit (success path)
    PERFORM public.commit_reserved_coins(p_attempt_id);
    
    -- Update attempt status
    UPDATE public.offline_attempts
    SET status = 'SYNCED',
        synced_at = NOW(),
        answers = p_answers
    WHERE id = p_attempt_id;
    
    RETURN jsonb_build_object(
        'success', true,
        'attempt_id', p_attempt_id,
        'score', score_result,
        'coins_committed', true
    );
    
EXCEPTION
    WHEN OTHERS THEN
        -- Any error = release coins
        PERFORM public.release_reserved_coins(p_attempt_id, 'Sync error: ' || SQLERRM);
        
        RETURN jsonb_build_object(
            'success', false,
            'error', 'sync_failed',
            'message', SQLERRM,
            'coins_released', true
        );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 6: CACHE INVALIDATION
-- ============================================================================

-- Function: Invalidate quiz cache
CREATE OR REPLACE FUNCTION public.invalidate_quiz_cache(
    p_quiz_id UUID,
    p_reason TEXT
)
RETURNS JSONB AS $$
DECLARE
    invalidated_count INTEGER;
BEGIN
    UPDATE public.quiz_cache_metadata
    SET is_valid = false,
        invalidated_at = NOW(),
        invalidation_reason = p_reason
    WHERE quiz_id = p_quiz_id
      AND is_valid = true;
    
    GET DIAGNOSTICS invalidated_count = ROW_COUNT;
    
    RETURN jsonb_build_object(
        'success', true,
        'invalidated_count', invalidated_count,
        'reason', p_reason
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger: Auto-invalidate cache on quiz update
CREATE OR REPLACE FUNCTION public.auto_invalidate_quiz_cache()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.version != OLD.version OR NEW.updated_at != OLD.updated_at THEN
        PERFORM public.invalidate_quiz_cache(NEW.id, 'Quiz updated');
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_invalidate_quiz_cache
    AFTER UPDATE ON public.assessments
    FOR EACH ROW
    EXECUTE FUNCTION public.auto_invalidate_quiz_cache();

-- PART 7: RLS POLICIES
-- ============================================================================

ALTER TABLE public.offline_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quiz_cache_metadata ENABLE ROW LEVEL SECURITY;

-- Users can only view/modify their own offline attempts
CREATE POLICY "Users manage own offline attempts"
    ON public.offline_attempts
    FOR ALL
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

-- Users can view valid quiz cache
CREATE POLICY "Users view valid quiz cache"
    ON public.quiz_cache_metadata
    FOR SELECT
    USING (is_valid = true AND expires_at > NOW());

-- Admins can view all offline attempts
CREATE POLICY "Admins view all offline attempts"
    ON public.offline_attempts
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid()
              AND role IN ('ops_admin', 'super_admin')
        )
    );

-- PART 8: CRON JOBS
-- ============================================================================

-- Purge expired cache daily
-- SELECT cron.schedule('purge-expired-quiz-cache', '0 6 * * *', $$
--     DELETE FROM public.quiz_cache_metadata
--     WHERE expires_at <= NOW() OR is_valid = false;
-- $$);

-- Auto-fail permanently stuck attempts (>24h)
-- SELECT cron.schedule('fail-stuck-offline-attempts', '0 */6 * * *', $$
--     UPDATE public.offline_attempts
--     SET status = 'FAILED_PERMANENT',
--         failed_at = NOW(),
--         rejection_reason = 'Sync timeout exceeded'
--     WHERE status IN ('PENDING_SYNC', 'SYNCING')
--       AND created_at < NOW() - INTERVAL '24 hours';
--     
--     -- Release coins for failed attempts
--     SELECT public.release_reserved_coins(id, 'Sync timeout')
--     FROM public.offline_attempts
--     WHERE status = 'FAILED_PERMANENT'
--       AND id IN (
--           SELECT reference_id FROM public.coin_ledger
--           WHERE state = 'RESERVED' AND reference_type = 'offline_attempt'
--       );
-- $$);

COMMENT ON TABLE public.offline_attempts IS 'Offline quiz attempts with strict state machine and coin escrow.';
COMMENT ON TABLE public.quiz_cache_metadata IS 'Quiz cache metadata with TTL and invalidation tracking.';
COMMENT ON FUNCTION public.reserve_coins_for_offline IS 'Reserve coins for offline attempt (AVAILABLE → RESERVED).';
COMMENT ON FUNCTION public.commit_reserved_coins IS 'Commit reserved coins on successful sync (RESERVED → COMMITTED).';
COMMENT ON FUNCTION public.release_reserved_coins IS 'Release reserved coins on rejection/failure (RESERVED → RELEASED).';
COMMENT ON FUNCTION public.sync_offline_attempt IS 'Validate and sync offline attempt with strict validation order.';
