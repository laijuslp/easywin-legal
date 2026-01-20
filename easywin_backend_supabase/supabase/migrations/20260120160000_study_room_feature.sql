-- ============================================================================
-- EASYWIN 1.0 - STUDY ROOM FEATURE
-- CANONICAL SSOT - LOCKED - NON-NEGOTIABLE
-- ============================================================================

-- PART 1: USER UNLOCKED QUESTIONS TABLE
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.user_unlocked_questions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    question_id UUID NOT NULL REFERENCES public.questions(id) ON DELETE CASCADE,
    unlocked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Ensure one unlock per user per question
    CONSTRAINT unique_user_question_unlock UNIQUE(user_id, question_id)
);

CREATE INDEX idx_user_unlocked_questions_user ON public.user_unlocked_questions(user_id);
CREATE INDEX idx_user_unlocked_questions_question ON public.user_unlocked_questions(question_id);
CREATE INDEX idx_user_unlocked_questions_unlocked_at ON public.user_unlocked_questions(unlocked_at DESC);

-- PART 2: USER QUESTION ATTEMPTS TABLE
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.user_question_attempts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    question_id UUID NOT NULL REFERENCES public.questions(id) ON DELETE CASCADE,
    attempt_no INTEGER NOT NULL CHECK (attempt_no > 0),
    score INTEGER NOT NULL CHECK (score >= 0),
    percentage DECIMAL(5,2) NOT NULL CHECK (percentage >= 0 AND percentage <= 100),
    attempted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Ensure unique attempt numbers per user per question
    CONSTRAINT unique_user_question_attempt UNIQUE(user_id, question_id, attempt_no)
);

CREATE INDEX idx_user_question_attempts_user ON public.user_question_attempts(user_id);
CREATE INDEX idx_user_question_attempts_question ON public.user_question_attempts(question_id);
CREATE INDEX idx_user_question_attempts_attempted_at ON public.user_question_attempts(attempted_at DESC);

-- PART 3: STUDY ROOM VIEW (READ-ONLY AGGREGATES)
-- ============================================================================

-- View: Study Room Unlocked Questions
CREATE OR REPLACE VIEW public.study_room_unlocked AS
SELECT 
    uq.user_id,
    q.id AS question_id,
    q.title,
    q.difficulty,
    uq.unlocked_at,
    -- Attempt stats
    COUNT(qa.id) AS attempt_count,
    MAX(qa.score) AS best_score,
    (SELECT qa2.score FROM public.user_question_attempts qa2 
     WHERE qa2.user_id = uq.user_id AND qa2.question_id = q.id 
     ORDER BY qa2.attempted_at DESC LIMIT 1) AS latest_score,
    MAX(qa.percentage) AS best_percentage,
    MAX(qa.attempted_at) AS last_attempted_at
FROM public.user_unlocked_questions uq
JOIN public.questions q ON q.id = uq.question_id
LEFT JOIN public.user_question_attempts qa ON qa.user_id = uq.user_id AND qa.question_id = q.id
GROUP BY uq.user_id, q.id, q.title, q.difficulty, uq.unlocked_at;

-- PART 4: UNLOCK QUESTION FUNCTION
-- ============================================================================

-- Function: Unlock question for user
CREATE OR REPLACE FUNCTION public.unlock_question(
    p_user_id UUID,
    p_question_id UUID
)
RETURNS JSONB AS $$
DECLARE
    already_unlocked BOOLEAN;
BEGIN
    -- Check if already unlocked
    SELECT EXISTS(
        SELECT 1 FROM public.user_unlocked_questions
        WHERE user_id = p_user_id AND question_id = p_question_id
    ) INTO already_unlocked;
    
    IF already_unlocked THEN
        RETURN jsonb_build_object(
            'success', true,
            'already_unlocked', true,
            'message', 'Question already unlocked'
        );
    END IF;
    
    -- Unlock question
    INSERT INTO public.user_unlocked_questions (user_id, question_id)
    VALUES (p_user_id, p_question_id);
    
    RETURN jsonb_build_object(
        'success', true,
        'already_unlocked', false,
        'message', 'Question unlocked successfully'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 5: RECORD ATTEMPT FUNCTION
-- ============================================================================

-- Function: Record question attempt
CREATE OR REPLACE FUNCTION public.record_question_attempt(
    p_user_id UUID,
    p_question_id UUID,
    p_score INTEGER,
    p_percentage DECIMAL
)
RETURNS JSONB AS $$
DECLARE
    is_unlocked BOOLEAN;
    next_attempt_no INTEGER;
BEGIN
    -- HARD CONSTRAINT: Only allow attempts if question is unlocked
    SELECT EXISTS(
        SELECT 1 FROM public.user_unlocked_questions
        WHERE user_id = p_user_id AND question_id = p_question_id
    ) INTO is_unlocked;
    
    IF NOT is_unlocked THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'question_not_unlocked',
            'message', 'You must unlock this question before attempting it'
        );
    END IF;
    
    -- Get next attempt number
    SELECT COALESCE(MAX(attempt_no), 0) + 1 INTO next_attempt_no
    FROM public.user_question_attempts
    WHERE user_id = p_user_id AND question_id = p_question_id;
    
    -- Record attempt (IMMUTABLE - NO UPDATES ALLOWED)
    INSERT INTO public.user_question_attempts (
        user_id,
        question_id,
        attempt_no,
        score,
        percentage
    ) VALUES (
        p_user_id,
        p_question_id,
        next_attempt_no,
        p_score,
        p_percentage
    );
    
    RETURN jsonb_build_object(
        'success', true,
        'attempt_no', next_attempt_no,
        'score', p_score,
        'percentage', p_percentage
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 6: GET STUDY ROOM DATA FUNCTIONS
-- ============================================================================

-- Function: Get unlocked questions for user
CREATE OR REPLACE FUNCTION public.get_study_room_unlocked(p_user_id UUID)
RETURNS TABLE(
    question_id UUID,
    title TEXT,
    difficulty TEXT,
    unlocked_at TIMESTAMPTZ,
    attempt_count BIGINT,
    best_score INTEGER,
    latest_score INTEGER,
    best_percentage DECIMAL,
    last_attempted_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        sr.question_id,
        sr.title,
        sr.difficulty,
        sr.unlocked_at,
        sr.attempt_count,
        sr.best_score,
        sr.latest_score,
        sr.best_percentage,
        sr.last_attempted_at
    FROM public.study_room_unlocked sr
    WHERE sr.user_id = p_user_id
    ORDER BY sr.unlocked_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Get attempted questions for user
CREATE OR REPLACE FUNCTION public.get_study_room_attempted(p_user_id UUID)
RETURNS TABLE(
    question_id UUID,
    title TEXT,
    difficulty TEXT,
    unlocked_at TIMESTAMPTZ,
    attempt_count BIGINT,
    best_score INTEGER,
    latest_score INTEGER,
    best_percentage DECIMAL,
    last_attempted_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        sr.question_id,
        sr.title,
        sr.difficulty,
        sr.unlocked_at,
        sr.attempt_count,
        sr.best_score,
        sr.latest_score,
        sr.best_percentage,
        sr.last_attempted_at
    FROM public.study_room_unlocked sr
    WHERE sr.user_id = p_user_id
      AND sr.attempt_count > 0
    ORDER BY sr.last_attempted_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Get attempt history for a question
CREATE OR REPLACE FUNCTION public.get_question_attempt_history(
    p_user_id UUID,
    p_question_id UUID
)
RETURNS TABLE(
    attempt_no INTEGER,
    score INTEGER,
    percentage DECIMAL,
    attempted_at TIMESTAMPTZ
) AS $$
BEGIN
    -- Verify ownership
    IF NOT EXISTS(
        SELECT 1 FROM public.user_unlocked_questions
        WHERE user_id = p_user_id AND question_id = p_question_id
    ) THEN
        RAISE EXCEPTION 'Question not unlocked';
    END IF;
    
    RETURN QUERY
    SELECT 
        qa.attempt_no,
        qa.score,
        qa.percentage,
        qa.attempted_at
    FROM public.user_question_attempts qa
    WHERE qa.user_id = p_user_id
      AND qa.question_id = p_question_id
    ORDER BY qa.attempt_no ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 7: RLS POLICIES (OWNERSHIP-BASED)
-- ============================================================================

ALTER TABLE public.user_unlocked_questions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_question_attempts ENABLE ROW LEVEL SECURITY;

-- Policy: Users can only view their own unlocked questions
CREATE POLICY "Users view own unlocked questions"
    ON public.user_unlocked_questions FOR SELECT
    USING (user_id = auth.uid());

-- Policy: Users can only insert their own unlocks (via RPC)
CREATE POLICY "Users unlock own questions"
    ON public.user_unlocked_questions FOR INSERT
    WITH CHECK (user_id = auth.uid());

-- Policy: Users can only view their own attempts
CREATE POLICY "Users view own attempts"
    ON public.user_question_attempts FOR SELECT
    USING (user_id = auth.uid());

-- Policy: Users can only insert their own attempts (via RPC)
CREATE POLICY "Users record own attempts"
    ON public.user_question_attempts FOR INSERT
    WITH CHECK (
        user_id = auth.uid() AND
        -- HARD CONSTRAINT: Must have unlocked the question
        EXISTS(
            SELECT 1 FROM public.user_unlocked_questions
            WHERE user_id = auth.uid() AND question_id = user_question_attempts.question_id
        )
    );

-- Policy: NO UPDATES ALLOWED (History is immutable)
-- Policy: NO DELETES ALLOWED (History is immutable)

-- Admins can view all unlocks and attempts
CREATE POLICY "Admins view all unlocks"
    ON public.user_unlocked_questions FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid()
              AND role IN ('ops_admin', 'super_admin')
        )
    );

CREATE POLICY "Admins view all attempts"
    ON public.user_question_attempts FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid()
              AND role IN ('ops_admin', 'super_admin')
        )
    );

COMMENT ON TABLE public.user_unlocked_questions IS 'User-owned unlocked questions. Study Room scope.';
COMMENT ON TABLE public.user_question_attempts IS 'Immutable attempt history. Read-only after insert.';
COMMENT ON VIEW public.study_room_unlocked IS 'Aggregated Study Room data with attempt stats.';
COMMENT ON FUNCTION public.unlock_question IS 'Unlock question for user (adds to Study Room).';
COMMENT ON FUNCTION public.record_question_attempt IS 'Record immutable attempt. Requires ownership.';
COMMENT ON FUNCTION public.get_study_room_unlocked IS 'Get all unlocked questions for Study Room.';
COMMENT ON FUNCTION public.get_study_room_attempted IS 'Get attempted questions for Study Room.';
COMMENT ON FUNCTION public.get_question_attempt_history IS 'Get read-only attempt history for a question.';
