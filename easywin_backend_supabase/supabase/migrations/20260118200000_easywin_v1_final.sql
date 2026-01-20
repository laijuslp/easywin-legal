-- =============================================================================
-- EASYWIN 1.0 — FINAL DATABASE SSOT
-- =============================================================================
-- Version: EasyWin 1.0
-- Backend: Supabase (PostgreSQL + RLS)
-- Philosophy: SSOT · No Learning State · No Leaderboards
-- =============================================================================

-- =============================================================================
-- 0️⃣ CLEANUP (FRESH START)
-- =============================================================================

-- Drop existing tables if they exist
DROP TABLE IF EXISTS public.rewarded_ads CASCADE;
DROP TABLE IF EXISTS public.coin_transactions CASCADE;
DROP TABLE IF EXISTS public.user_wallet CASCADE;
DROP TABLE IF EXISTS public.user_unlocks CASCADE;
DROP TABLE IF EXISTS public.assessment_cooldowns CASCADE;
DROP TABLE IF EXISTS public.assessment_attempts CASCADE;
DROP TABLE IF EXISTS public.questions CASCADE;
DROP TABLE IF EXISTS public.exams CASCADE;
DROP TABLE IF EXISTS public.quizzes CASCADE;
DROP TABLE IF EXISTS public.categories CASCADE;
DROP TABLE IF EXISTS public.user_courses CASCADE;
DROP TABLE IF EXISTS public.courses CASCADE;
DROP TABLE IF EXISTS public.profiles CASCADE;

-- Drop legacy tables from previous versions
DROP TABLE IF EXISTS public.abuse_flags CASCADE;
DROP TABLE IF EXISTS public.feature_flags CASCADE;
DROP TABLE IF EXISTS public.offline_attempts CASCADE;
DROP TABLE IF EXISTS public.question_reviews CASCADE;
DROP TABLE IF EXISTS public.question_versions CASCADE;
DROP TABLE IF EXISTS public.question_bank CASCADE;
DROP TABLE IF EXISTS public.audit_logs CASCADE;
DROP TABLE IF EXISTS public.moderation_reports CASCADE;
DROP TABLE IF EXISTS public.leaderboard_entries CASCADE;
DROP TABLE IF EXISTS public.subscriptions CASCADE;
DROP TABLE IF EXISTS public.coin_packs CASCADE;
DROP TABLE IF EXISTS public.assessment_history CASCADE;

-- Drop triggers on auth.users if they exist
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

-- Drop legacy functions
DROP FUNCTION IF EXISTS public.handle_new_user() CASCADE;
DROP FUNCTION IF EXISTS public.update_updated_at_column() CASCADE;
DROP FUNCTION IF EXISTS public.start_assessment(UUID, UUID) CASCADE;
DROP FUNCTION IF EXISTS public.submit_assessment(public.assessment_type, JSONB, UUID, UUID) CASCADE;
DROP FUNCTION IF EXISTS public.start_learning_session(UUID, UUID) CASCADE;
DROP FUNCTION IF EXISTS public.get_assessment_status(UUID, UUID) CASCADE;
DROP FUNCTION IF EXISTS public.award_coins(UUID, TEXT, INTEGER, TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.unlock_content(UUID, UUID, UUID) CASCADE;

-- Drop existing types
DROP TYPE IF EXISTS public.account_type CASCADE;
DROP TYPE IF EXISTS public.assessment_type CASCADE;
DROP TYPE IF EXISTS public.content_state CASCADE;
DROP TYPE IF EXISTS public.offline_status CASCADE;
DROP TYPE IF EXISTS public.moderation_status CASCADE;
DROP TYPE IF EXISTS public.subscription_status CASCADE;
DROP TYPE IF EXISTS public.transaction_type CASCADE;
DROP TYPE IF EXISTS public.content_type CASCADE;
DROP TYPE IF EXISTS public.session_type CASCADE;


-- =============================================================================
-- 1️⃣ EXTENSIONS
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =============================================================================
-- 2️⃣ ENUM TYPES
-- =============================================================================

CREATE TYPE public.account_type AS ENUM ('free', 'pro', 'premium');

CREATE TYPE public.assessment_type AS ENUM (
  'assessment_1',
  'assessment_2',
  'assessment_3'
);

-- =============================================================================
-- 3️⃣ CORE IDENTITY
-- =============================================================================

CREATE TABLE public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,

  email TEXT UNIQUE NOT NULL,
  display_name TEXT,
  username TEXT UNIQUE,
  avatar_url TEXT,

  account_type public.account_type NOT NULL DEFAULT 'free',

  total_score INTEGER NOT NULL DEFAULT 0,
  quizzes_completed INTEGER NOT NULL DEFAULT 0,
  exams_completed INTEGER NOT NULL DEFAULT 0,

  current_streak INTEGER NOT NULL DEFAULT 0,
  longest_streak INTEGER NOT NULL DEFAULT 0,
  last_activity_date DATE,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- 4️⃣ COURSES (EXAMS TAB ROOT)
-- =============================================================================

CREATE TABLE public.courses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  title TEXT NOT NULL,
  description TEXT,
  price_inr NUMERIC(10,2),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,

  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.user_courses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  course_id UUID NOT NULL REFERENCES public.courses(id) ON DELETE CASCADE,
  purchased_at TIMESTAMPTZ DEFAULT NOW(),

  UNIQUE (user_id, course_id)
);

-- =============================================================================
-- 5️⃣ CATEGORIES (COMMON BRIDGE)
-- =============================================================================

CREATE TABLE public.categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  course_id UUID REFERENCES public.courses(id) ON DELETE SET NULL,

  name TEXT NOT NULL,
  description TEXT,
  display_order INTEGER DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,

  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================================================
-- 6️⃣ QUIZZES (QUIZZES TAB)
-- =============================================================================

CREATE TABLE public.quizzes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  category_id UUID NOT NULL REFERENCES public.categories(id) ON DELETE CASCADE,

  title TEXT NOT NULL,
  total_questions INTEGER NOT NULL DEFAULT 20,

  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================================================
-- 7️⃣ EXAMS (COURSE-DRIVEN)
-- =============================================================================

CREATE TABLE public.exams (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  category_id UUID NOT NULL REFERENCES public.categories(id) ON DELETE CASCADE,

  title TEXT NOT NULL,
  total_questions INTEGER NOT NULL CHECK (total_questions IN (20, 50, 100)),

  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================================================
-- 8️⃣ QUESTIONS (PURE CONTENT)
-- =============================================================================

CREATE TABLE public.questions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  quiz_id UUID REFERENCES public.quizzes(id) ON DELETE CASCADE,
  exam_id UUID REFERENCES public.exams(id) ON DELETE CASCADE,

  question_text TEXT NOT NULL,

  option_a TEXT NOT NULL,
  option_b TEXT NOT NULL,
  option_c TEXT NOT NULL,
  option_d TEXT NOT NULL,

  correct_option CHAR(1) CHECK (correct_option IN ('A','B','C','D')),

  explanation TEXT,

  created_at TIMESTAMPTZ DEFAULT NOW(),

  CONSTRAINT one_parent CHECK (
    (quiz_id IS NOT NULL AND exam_id IS NULL)
    OR
    (quiz_id IS NULL AND exam_id IS NOT NULL)
  )
);

-- =============================================================================
-- 9️⃣ ASSESSMENTS (RANK SCREEN SOURCE)
-- =============================================================================

CREATE TABLE public.assessment_attempts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  quiz_id UUID REFERENCES public.quizzes(id) ON DELETE CASCADE,
  exam_id UUID REFERENCES public.exams(id) ON DELETE CASCADE,

  assessment_type public.assessment_type NOT NULL,

  score INTEGER NOT NULL CHECK (score BETWEEN 0 AND 100),
  total_questions INTEGER NOT NULL,
  correct_answers INTEGER NOT NULL,

  completed_at TIMESTAMPTZ DEFAULT NOW(),

  CONSTRAINT one_content CHECK (
    (quiz_id IS NOT NULL AND exam_id IS NULL)
    OR
    (quiz_id IS NULL AND exam_id IS NOT NULL)
  )
);

CREATE TABLE public.assessment_cooldowns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  quiz_id UUID REFERENCES public.quizzes(id) ON DELETE CASCADE,
  exam_id UUID REFERENCES public.exams(id) ON DELETE CASCADE,

  assessment_type public.assessment_type NOT NULL,
  unlocks_at TIMESTAMPTZ NOT NULL,

  created_at TIMESTAMPTZ DEFAULT NOW(),
  
  CONSTRAINT one_cooldown_content CHECK (
    (quiz_id IS NOT NULL AND exam_id IS NULL)
    OR
    (quiz_id IS NULL AND exam_id IS NOT NULL)
  )
);

-- =============================================================================
-- 🔟 ACCESS CONTROL
-- =============================================================================

CREATE TABLE public.user_unlocks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  quiz_id UUID REFERENCES public.quizzes(id) ON DELETE CASCADE,
  exam_id UUID REFERENCES public.exams(id) ON DELETE CASCADE,

  unlocked_at TIMESTAMPTZ DEFAULT NOW(),

  CONSTRAINT one_unlock CHECK (
    (quiz_id IS NOT NULL AND exam_id IS NULL)
    OR
    (quiz_id IS NULL AND exam_id IS NOT NULL)
  )
);

-- =============================================================================
-- 11️⃣ COINS (SIMPLE & SAFE)
-- =============================================================================

CREATE TABLE public.user_wallet (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  balance INTEGER NOT NULL DEFAULT 0 CHECK (balance >= 0),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.coin_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  amount INTEGER NOT NULL,
  reason TEXT NOT NULL,

  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.rewarded_ads (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  rewarded_at TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================================================
-- 12️⃣ TRIGGERS & FUNCTIONS
-- =============================================================================

-- Auto-update updated_at column
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_profiles_updated_at BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_courses_updated_at BEFORE UPDATE ON public.courses FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_categories_updated_at BEFORE UPDATE ON public.categories FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_quizzes_updated_at BEFORE UPDATE ON public.quizzes FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_exams_updated_at BEFORE UPDATE ON public.exams FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_user_wallet_updated_at BEFORE UPDATE ON public.user_wallet FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Auth trigger to setup profile and wallet
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, email, display_name, avatar_url)
  VALUES (
    NEW.id,
    NEW.email,
    NEW.raw_user_meta_data->>'display_name',
    NEW.raw_user_meta_data->>'avatar_url'
  );

  INSERT INTO public.user_wallet (user_id, balance)
  VALUES (NEW.id, 100); -- Initial 100 bonus coins

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- =============================================================================
-- 13️⃣ ROW LEVEL SECURITY (RLS)
-- =============================================================================

-- Enable RLS
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.courses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_courses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quizzes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exams ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.questions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assessment_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assessment_cooldowns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_unlocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_wallet ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.coin_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rewarded_ads ENABLE ROW LEVEL SECURITY;

-- Profiles: Publicly viewable, owners can update
CREATE POLICY "Profiles are viewable by everyone" ON public.profiles FOR SELECT USING (true);
CREATE POLICY "Users can update own profile" ON public.profiles FOR UPDATE USING (auth.uid() = id);

-- Courses & Categories: Publicly viewable
CREATE POLICY "Courses are viewable by everyone" ON public.courses FOR SELECT USING (is_active = true);
CREATE POLICY "Categories are viewable by everyone" ON public.categories FOR SELECT USING (is_active = true);

-- Quizzes & Exams: Viewable by everyone
CREATE POLICY "Quizzes are viewable by everyone" ON public.quizzes FOR SELECT USING (true);
CREATE POLICY "Exams are viewable by everyone" ON public.exams FOR SELECT USING (true);

-- Questions: Viewable by authenticated users (logic in app for specific access)
CREATE POLICY "Questions are viewable by authenticated" ON public.questions FOR SELECT TO authenticated USING (true);

-- Assessment Attempts: View own only
CREATE POLICY "Users can view own attempts" ON public.assessment_attempts FOR SELECT USING (auth.uid() = user_id);

-- Wallet: View own only
CREATE POLICY "Users can view own wallet" ON public.user_wallet FOR SELECT USING (auth.uid() = user_id);

-- Unlocks: View own only
CREATE POLICY "Users can view own unlocks" ON public.user_unlocks FOR SELECT USING (auth.uid() = user_id);

-- Rewarded Ads: View own only
CREATE POLICY "Users can view own rewards" ON public.rewarded_ads FOR SELECT USING (auth.uid() = user_id);


-- =============================================================================
-- 14️⃣ CORE RPCs
-- =============================================================================

-- Start Assessment RPC
CREATE OR REPLACE FUNCTION public.start_assessment(
  p_quiz_id UUID DEFAULT NULL,
  p_exam_id UUID DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_next_assessment public.assessment_type;
  v_cooldown_unlocks_at TIMESTAMPTZ;
  v_a1_exists BOOLEAN;
  v_a2_exists BOOLEAN;
  v_questions JSONB;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Unauthorized'); END IF;

  -- Logic: Check A1 -> A2 -> A3 (A3 repeats)
  SELECT EXISTS(SELECT 1 FROM public.assessment_attempts WHERE user_id = v_user_id AND (quiz_id = p_quiz_id OR exam_id = p_exam_id) AND assessment_type = 'assessment_1') INTO v_a1_exists;
  SELECT EXISTS(SELECT 1 FROM public.assessment_attempts WHERE user_id = v_user_id AND (quiz_id = p_quiz_id OR exam_id = p_exam_id) AND assessment_type = 'assessment_2') INTO v_a2_exists;

  IF NOT v_a1_exists THEN v_next_assessment := 'assessment_1';
  ELSIF NOT v_a2_exists THEN v_next_assessment := 'assessment_2';
  ELSE v_next_assessment := 'assessment_3';
  END IF;

  -- Check Cooldown
  SELECT unlocks_at INTO v_cooldown_unlocks_at FROM public.assessment_cooldowns 
  WHERE user_id = v_user_id AND (quiz_id = p_quiz_id OR exam_id = p_exam_id) AND assessment_type = v_next_assessment AND unlocks_at > NOW();

  IF v_cooldown_unlocks_at IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'On cooldown', 'unlocks_at', v_cooldown_unlocks_at);
  END IF;

  -- Get Questions
  SELECT jsonb_agg(q) INTO v_questions FROM (
    SELECT id, question_text, option_a, option_b, option_c, option_d FROM public.questions
    WHERE (quiz_id = p_quiz_id OR exam_id = p_exam_id)
    ORDER BY RANDOM()
  ) q;

  RETURN jsonb_build_object(
    'success', true,
    'assessment_type', v_next_assessment,
    'questions', v_questions
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Submit Assessment RPC
CREATE OR REPLACE FUNCTION public.submit_assessment(
  p_assessment_type public.assessment_type,
  p_answers JSONB,
  p_quiz_id UUID DEFAULT NULL,
  p_exam_id UUID DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_total_questions INTEGER;
  v_correct_answers INTEGER := 0;
  v_score INTEGER;
  v_ans RECORD;
  v_correct_ans CHAR(1);
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Unauthorized'); END IF;

  v_total_questions := jsonb_array_length(p_answers);
  
  -- Calculate Correct Answers
  FOR v_ans IN SELECT * FROM jsonb_to_recordset(p_answers) AS x(question_id UUID, selected_option CHAR(1)) LOOP
    SELECT correct_option INTO v_correct_ans FROM public.questions WHERE id = v_ans.question_id;
    IF v_correct_ans = v_ans.selected_option THEN
      v_correct_answers := v_correct_answers + 1;
    END IF;
  END LOOP;

  v_score := ROUND((v_correct_answers::FLOAT / v_total_questions::FLOAT) * 100);

  -- Record Attempt
  INSERT INTO public.assessment_attempts (user_id, quiz_id, exam_id, assessment_type, score, total_questions, correct_answers)
  VALUES (v_user_id, p_quiz_id, p_exam_id, p_assessment_type, v_score, v_total_questions, v_correct_answers);

  -- Set Cooldown (24 hours)
  INSERT INTO public.assessment_cooldowns (user_id, quiz_id, exam_id, assessment_type, unlocks_at)
  VALUES (v_user_id, p_quiz_id, p_exam_id, p_assessment_type, NOW() + INTERVAL '24 hours')
  ON CONFLICT (id) DO UPDATE SET unlocks_at = EXCLUDED.unlocks_at;

  -- Update Profile Aggregates
  UPDATE public.profiles 
  SET 
    total_score = total_score + v_score,
    quizzes_completed = quizzes_completed + (CASE WHEN p_quiz_id IS NOT NULL THEN 1 ELSE 0 END),
    exams_completed = exams_completed + (CASE WHEN p_exam_id IS NOT NULL THEN 1 ELSE 0 END),
    updated_at = NOW(),
    last_activity_date = CURRENT_DATE
  WHERE id = v_user_id;

  RETURN jsonb_build_object(
    'success', true,
    'score', v_score,
    'correct_answers', v_correct_answers,
    'total_questions', v_total_questions
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================================================================
-- 15️⃣ USER ROLES (ADMIN ACCESS)
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('admin', 'moderator')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_id, role)
);

ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can view all roles" ON public.user_roles FOR SELECT TO authenticated USING (
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
);

CREATE POLICY "Admins can manage roles" ON public.user_roles FOR ALL TO authenticated USING (
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
);
