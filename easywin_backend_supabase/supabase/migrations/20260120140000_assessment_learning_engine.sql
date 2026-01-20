-- ============================================================================
-- EASYWIN 1.0 - ASSESSMENT & LEARNING ENGINE
-- CANONICAL SSOT - LOCKED - NON-NEGOTIABLE
-- Version: v1.0 · FINAL
-- ============================================================================

-- PART 1: ASSESSMENT TYPES & MODES
-- ============================================================================

CREATE TYPE public.assessment_mode AS ENUM (
    'assessment_1',
    'assessment_2',
    'assessment_3',
    'learning'
);

-- PART 2: ASSESSMENT ATTEMPTS TABLE (RECORDED ONLY)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.assessment_attempts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    quiz_id UUID NOT NULL REFERENCES public.assessments(id) ON DELETE RESTRICT,
    
    -- Mode (ASSESSMENT ONLY - Learning is never recorded)
    mode public.assessment_mode NOT NULL CHECK (mode != 'learning'),
    
    -- Assessment metadata
    assessment_number INTEGER NOT NULL CHECK (assessment_number IN (1, 2, 3)),
    question_count INTEGER NOT NULL,
    time_limit_seconds INTEGER NOT NULL,
    marks_per_question INTEGER NOT NULL DEFAULT 1,
    
    -- Randomization seed (for reproducibility)
    question_order_seed INTEGER NOT NULL,
    
    -- Answers
    answers JSONB NOT NULL DEFAULT '[]'::JSONB,
    
    -- Scoring
    score INTEGER,
    max_score INTEGER,
    correct_count INTEGER,
    incorrect_count INTEGER,
    
    -- Timing
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    submitted_at TIMESTAMPTZ,
    time_taken_seconds INTEGER,
    
    -- Assessment Ranking eligibility
    is_assessment_ranking_eligible BOOLEAN DEFAULT true,
    
    -- Status
    status TEXT NOT NULL DEFAULT 'in_progress' CHECK (
        status IN ('in_progress', 'submitted', 'abandoned')
    ),
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT valid_submission CHECK (
        (status != 'submitted') OR 
        (submitted_at IS NOT NULL AND score IS NOT NULL)
    ),
    CONSTRAINT unique_user_quiz_assessment UNIQUE(user_id, quiz_id, assessment_number)
);

CREATE INDEX idx_assessment_attempts_user ON public.assessment_attempts(user_id, quiz_id);
CREATE INDEX idx_assessment_attempts_ranking ON public.assessment_attempts(quiz_id, assessment_number, score DESC) 
    WHERE status = 'submitted' AND is_assessment_ranking_eligible = true;

-- PART 3: ASSESSMENT COOLDOWNS TABLE
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.assessment_cooldowns (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    quiz_id UUID NOT NULL REFERENCES public.assessments(id) ON DELETE CASCADE,
    assessment_number INTEGER NOT NULL CHECK (assessment_number IN (1, 2, 3)),
    
    -- Cooldown period
    locked_until TIMESTAMPTZ NOT NULL,
    
    -- Metadata
    created_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT unique_user_quiz_cooldown UNIQUE(user_id, quiz_id, assessment_number)
);

CREATE INDEX idx_assessment_cooldowns_active ON public.assessment_cooldowns(user_id, quiz_id, locked_until) 
    WHERE locked_until > NOW();

-- PART 4: ASSESSMENT AVAILABILITY FUNCTION
-- ============================================================================

-- Function: Get assessment availability for user
CREATE OR REPLACE FUNCTION public.get_assessment_availability(
    p_user_id UUID,
    p_quiz_id UUID
)
RETURNS JSONB AS $$
DECLARE
    assessment_1_completed BOOLEAN;
    assessment_2_completed BOOLEAN;
    assessment_3_completed BOOLEAN;
    assessment_1_cooldown TIMESTAMPTZ;
    assessment_2_cooldown TIMESTAMPTZ;
    assessment_3_cooldown TIMESTAMPTZ;
    result JSONB;
BEGIN
    -- Check completed assessments
    SELECT 
        EXISTS(SELECT 1 FROM public.assessment_attempts 
               WHERE user_id = p_user_id AND quiz_id = p_quiz_id 
               AND assessment_number = 1 AND status = 'submitted'),
        EXISTS(SELECT 1 FROM public.assessment_attempts 
               WHERE user_id = p_user_id AND quiz_id = p_quiz_id 
               AND assessment_number = 2 AND status = 'submitted'),
        EXISTS(SELECT 1 FROM public.assessment_attempts 
               WHERE user_id = p_user_id AND quiz_id = p_quiz_id 
               AND assessment_number = 3 AND status = 'submitted')
    INTO assessment_1_completed, assessment_2_completed, assessment_3_completed;
    
    -- Check cooldowns
    SELECT locked_until INTO assessment_1_cooldown
    FROM public.assessment_cooldowns
    WHERE user_id = p_user_id AND quiz_id = p_quiz_id 
    AND assessment_number = 1 AND locked_until > NOW();
    
    SELECT locked_until INTO assessment_2_cooldown
    FROM public.assessment_cooldowns
    WHERE user_id = p_user_id AND quiz_id = p_quiz_id 
    AND assessment_number = 2 AND locked_until > NOW();
    
    SELECT locked_until INTO assessment_3_cooldown
    FROM public.assessment_cooldowns
    WHERE user_id = p_user_id AND quiz_id = p_quiz_id 
    AND assessment_number = 3 AND locked_until > NOW();
    
    -- Build result
    result := jsonb_build_object(
        'learning', jsonb_build_object(
            'available', true,
            'label', 'Learning',
            'description', 'Practice mode — scores are not recorded.'
        ),
        'assessment_1', jsonb_build_object(
            'available', NOT assessment_1_completed AND assessment_1_cooldown IS NULL,
            'completed', assessment_1_completed,
            'locked_until', assessment_1_cooldown,
            'label', 'Assessment 1',
            'time_per_question', 0.50,
            'marks_per_question', 1
        ),
        'assessment_2', jsonb_build_object(
            'available', assessment_1_completed AND NOT assessment_2_completed AND assessment_2_cooldown IS NULL,
            'completed', assessment_2_completed,
            'locked_until', assessment_2_cooldown,
            'label', 'Assessment 2',
            'time_per_question', 0.40,
            'marks_per_question', 1,
            'requires', 'Assessment 1 completion'
        ),
        'assessment_3', jsonb_build_object(
            'available', assessment_2_completed AND assessment_3_cooldown IS NULL,
            'completed', assessment_3_completed,
            'locked_until', assessment_3_cooldown,
            'label', 'Assessment 3',
            'time_per_question', 0.30,
            'marks_per_question', 1,
            'requires', 'Assessment 2 completion',
            'retakeable', true
        )
    );
    
    RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 5: START ASSESSMENT FUNCTION
-- ============================================================================

-- Function: Start assessment (with randomization)
CREATE OR REPLACE FUNCTION public.start_assessment(
    p_user_id UUID,
    p_quiz_id UUID,
    p_mode public.assessment_mode
)
RETURNS JSONB AS $$
DECLARE
    quiz RECORD;
    availability JSONB;
    assessment_number INTEGER;
    time_limit_seconds INTEGER;
    question_order_seed INTEGER;
    attempt_id UUID;
BEGIN
    -- Learning mode is never recorded
    IF p_mode = 'learning' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'learning_not_recorded',
            'message', 'Learning sessions are not recorded. Use client-side state only.'
        );
    END IF;
    
    -- Get quiz details
    SELECT * INTO quiz
    FROM public.assessments
    WHERE id = p_quiz_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'quiz_not_found');
    END IF;
    
    -- Check availability
    availability := public.get_assessment_availability(p_user_id, p_quiz_id);
    
    -- Determine assessment number
    assessment_number := CASE p_mode
        WHEN 'assessment_1' THEN 1
        WHEN 'assessment_2' THEN 2
        WHEN 'assessment_3' THEN 3
        ELSE NULL
    END;
    
    -- Check if available
    IF NOT (availability -> ('assessment_' || assessment_number) ->> 'available')::BOOLEAN THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'assessment_not_available',
            'locked_until', availability -> ('assessment_' || assessment_number) ->> 'locked_until'
        );
    END IF;
    
    -- Calculate time limit (based on question count and time per question)
    time_limit_seconds := CASE assessment_number
        WHEN 1 THEN CEIL(quiz.question_count * 0.50)::INTEGER
        WHEN 2 THEN CEIL(quiz.question_count * 0.40)::INTEGER
        WHEN 3 THEN CEIL(quiz.question_count * 0.30)::INTEGER
    END;
    
    -- Generate randomization seed
    question_order_seed := FLOOR(RANDOM() * 2147483647)::INTEGER;
    
    -- Create attempt
    INSERT INTO public.assessment_attempts (
        user_id,
        quiz_id,
        mode,
        assessment_number,
        question_count,
        time_limit_seconds,
        marks_per_question,
        question_order_seed
    ) VALUES (
        p_user_id,
        p_quiz_id,
        p_mode,
        assessment_number,
        quiz.question_count,
        time_limit_seconds,
        1,
        question_order_seed
    ) RETURNING id INTO attempt_id;
    
    RETURN jsonb_build_object(
        'success', true,
        'attempt_id', attempt_id,
        'assessment_number', assessment_number,
        'question_count', quiz.question_count,
        'time_limit_seconds', time_limit_seconds,
        'question_order_seed', question_order_seed,
        'feedback_enabled', false -- STRICT: No feedback in assessments
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 6: SUBMIT ASSESSMENT FUNCTION
-- ============================================================================

-- Function: Submit assessment
CREATE OR REPLACE FUNCTION public.submit_assessment(
    p_attempt_id UUID,
    p_answers JSONB
)
RETURNS JSONB AS $$
DECLARE
    attempt RECORD;
    quiz RECORD;
    correct_count INTEGER := 0;
    total_questions INTEGER;
    score INTEGER;
    max_score INTEGER;
    next_cooldown_until TIMESTAMPTZ;
BEGIN
    -- Get attempt
    SELECT * INTO attempt
    FROM public.assessment_attempts
    WHERE id = p_attempt_id
      AND status = 'in_progress';
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'attempt_not_found_or_already_submitted');
    END IF;
    
    -- Get quiz
    SELECT * INTO quiz
    FROM public.assessments
    WHERE id = attempt.quiz_id;
    
    -- Calculate score (simplified - actual logic would validate against correct answers)
    total_questions := jsonb_array_length(p_answers);
    max_score := total_questions * attempt.marks_per_question;
    
    -- TODO: Actual scoring logic here
    -- For now, assume score is provided or calculated
    score := 0; -- Placeholder
    
    -- Update attempt
    UPDATE public.assessment_attempts
    SET status = 'submitted',
        submitted_at = NOW(),
        answers = p_answers,
        score = score,
        max_score = max_score,
        correct_count = correct_count,
        incorrect_count = total_questions - correct_count,
        time_taken_seconds = EXTRACT(EPOCH FROM (NOW() - started_at))::INTEGER
    WHERE id = p_attempt_id;
    
    -- Set cooldown for next assessment (24 hours)
    next_cooldown_until := NOW() + INTERVAL '24 hours';
    
    IF attempt.assessment_number < 3 THEN
        -- Lock next assessment
        INSERT INTO public.assessment_cooldowns (
            user_id,
            quiz_id,
            assessment_number,
            locked_until
        ) VALUES (
            attempt.user_id,
            attempt.quiz_id,
            attempt.assessment_number + 1,
            next_cooldown_until
        ) ON CONFLICT (user_id, quiz_id, assessment_number) 
        DO UPDATE SET locked_until = next_cooldown_until;
    ELSE
        -- Assessment 3 can be retaken after 24 hours
        INSERT INTO public.assessment_cooldowns (
            user_id,
            quiz_id,
            assessment_number,
            locked_until
        ) VALUES (
            attempt.user_id,
            attempt.quiz_id,
            3,
            next_cooldown_until
        ) ON CONFLICT (user_id, quiz_id, assessment_number) 
        DO UPDATE SET locked_until = next_cooldown_until;
    END IF;
    
    RETURN jsonb_build_object(
        'success', true,
        'score', score,
        'max_score', max_score,
        'correct_count', correct_count,
        'total_questions', total_questions,
        'next_assessment_available_at', next_cooldown_until,
        'learning_available', true
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 7: ASSESSMENT RANKING FUNCTION
-- ============================================================================

-- Function: Get assessment ranking (Assessment 3 → 2 → 1)
CREATE OR REPLACE FUNCTION public.get_assessment_ranking(
    p_quiz_id UUID,
    p_assessment_number INTEGER DEFAULT 3,
    p_limit INTEGER DEFAULT 100
)
RETURNS TABLE(
    rank BIGINT,
    user_id UUID,
    username TEXT,
    score INTEGER,
    max_score INTEGER,
    submitted_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ROW_NUMBER() OVER (ORDER BY a.score DESC, a.submitted_at ASC) as rank,
        a.user_id,
        p.username,
        a.score,
        a.max_score,
        a.submitted_at
    FROM public.assessment_attempts a
    JOIN public.profiles p ON p.id = a.user_id
    WHERE a.quiz_id = p_quiz_id
      AND a.assessment_number = p_assessment_number
      AND a.status = 'submitted'
      AND a.is_assessment_ranking_eligible = true
    ORDER BY a.score DESC, a.submitted_at ASC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 8: RLS POLICIES
-- ============================================================================

ALTER TABLE public.assessment_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assessment_cooldowns ENABLE ROW LEVEL SECURITY;

-- Users can view their own attempts
CREATE POLICY "Users view own assessment attempts"
    ON public.assessment_attempts FOR SELECT
    USING (user_id = auth.uid());

-- Users can insert their own attempts
CREATE POLICY "Users create own assessment attempts"
    ON public.assessment_attempts FOR INSERT
    WITH CHECK (user_id = auth.uid());

-- Users can update their own in-progress attempts
CREATE POLICY "Users update own in-progress attempts"
    ON public.assessment_attempts FOR UPDATE
    USING (user_id = auth.uid() AND status = 'in_progress')
    WITH CHECK (user_id = auth.uid());

-- Users can view their own cooldowns
CREATE POLICY "Users view own cooldowns"
    ON public.assessment_cooldowns FOR SELECT
    USING (user_id = auth.uid());

-- Admins can view all attempts
CREATE POLICY "Admins view all attempts"
    ON public.assessment_attempts FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid()
              AND role IN ('ops_admin', 'super_admin', 'content_admin')
        )
    );

COMMENT ON TABLE public.assessment_attempts IS 'Recorded assessment attempts only. Learning is never recorded.';
COMMENT ON TABLE public.assessment_cooldowns IS '24-hour cooldowns between assessments.';
COMMENT ON FUNCTION public.get_assessment_availability IS 'Get assessment availability and learning status for user.';
COMMENT ON FUNCTION public.start_assessment IS 'Start assessment with randomization. Learning is client-side only.';
COMMENT ON FUNCTION public.submit_assessment IS 'Submit assessment and set 24-hour cooldown.';
COMMENT ON FUNCTION public.get_assessment_ranking IS 'Get assessment ranking (Assessment 3 default, then 2, then 1).';
