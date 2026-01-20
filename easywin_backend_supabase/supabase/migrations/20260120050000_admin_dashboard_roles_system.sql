-- =============================================================================
-- EASYWIN 1.0 ADMIN DASHBOARD — ROLE-BASED SYSTEM (FIXED)
-- Modules 1-5: Content Authoring, Bulk Upload, Ops Dashboard, Abuse, Audit
-- =============================================================================

-- =============================================================================
-- PART 0: FIX USER_ROLES TYPE (CRITICAL FIX)
-- =============================================================================

-- It appears user_roles.role is an ENUM 'app_role' in the remote DB.
-- We must convert it to TEXT to support dynamic roles without strict enum maintenance.

 DO $$ 
BEGIN
    -- 0. Drop dependent policies causing type-alteration errors
    
    -- Drop dependent policies on other tables
    IF EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'Admins can manage avatars' AND tablename = 'avatars') THEN
        DROP POLICY "Admins can manage avatars" ON public.avatars;
    END IF;

    BEGIN
        DROP POLICY IF EXISTS "Admins can manage avatar images" ON storage.objects;
        DROP POLICY IF EXISTS "Admin Upload" ON storage.objects;
        DROP POLICY IF EXISTS "Admin Select" ON storage.objects;
        DROP POLICY IF EXISTS "Admin Update" ON storage.objects;
        DROP POLICY IF EXISTS "Admin Delete" ON storage.objects;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    -- Drop dependent functions
    DROP FUNCTION IF EXISTS public.has_role(uuid, app_role) CASCADE;
    DROP FUNCTION IF EXISTS public.has_role(app_role) CASCADE;
    
    -- Drop dependent policies
    -- "Admins manage assessments" on assessment_attempts
    IF EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'Admins manage assessments' AND tablename = 'assessment_attempts') THEN
        DROP POLICY "Admins manage assessments" ON public.assessment_attempts;
    END IF;

    -- Drop policies on user_roles itself that might use the column
    DROP POLICY IF EXISTS "diagnostic_roles_admin" ON public.user_roles;
    DROP POLICY IF EXISTS "Admins can view all roles" ON public.user_roles;
    DROP POLICY IF EXISTS "Admins can manage roles" ON public.user_roles;
    DROP POLICY IF EXISTS "Users can view own roles" ON public.user_roles;
    DROP POLICY IF EXISTS "Allow authenticated read" ON public.user_roles;


    -- 1. Alter column to TEXT (strips the enum type association)
    ALTER TABLE public.user_roles ALTER COLUMN role TYPE TEXT;

    -- 2. Drop the generated constraint if it exists
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_roles_role_check' AND conrelid = 'public.user_roles'::regclass) THEN
        ALTER TABLE public.user_roles DROP CONSTRAINT user_roles_role_check;
    END IF;

    -- 3. Drop the enum type (CASCADE to remove any lingering dependencies)
    DROP TYPE IF EXISTS app_role CASCADE; 
END $$;

-- 4. Apply the new check constraint with all required roles
ALTER TABLE public.user_roles ADD CONSTRAINT user_roles_role_check 
  CHECK (role IN ('admin', 'moderator', 'author', 'reviewer', 'content_admin', 'ops_admin', 'super_admin'));

-- 5. Recreate the dropped policies (works with TEXT role now)

-- Recreate policies on user_roles
CREATE POLICY "Allow authenticated read" ON public.user_roles 
FOR SELECT TO authenticated USING (true);

CREATE POLICY "Admins can manage roles" ON public.user_roles 
FOR ALL TO authenticated USING (
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
);

-- Recreate policies on avatars
CREATE POLICY "Admins can manage avatars" ON public.avatars 
FOR ALL TO authenticated USING (
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
);

-- Recreate policies on storage.objects
CREATE POLICY "Admins can manage avatar images" ON storage.objects
FOR ALL TO authenticated USING (
  bucket_id = 'avatars' AND
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
);


-- =============================================================================
-- PART 1: CONTENT LIFECYCLE TABLES (MODULE 1)
-- =============================================================================

-- Question versions (immutable history)
CREATE TABLE IF NOT EXISTS public.question_versions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  question_id UUID, -- NULL for first version, then references parent
  version_number INTEGER NOT NULL DEFAULT 1,
  
  -- Content fields
  question_text TEXT NOT NULL,
  option_a TEXT NOT NULL,
  option_b TEXT NOT NULL,
  option_c TEXT NOT NULL,
  option_d TEXT NOT NULL,
  correct_option TEXT NOT NULL CHECK (correct_option IN ('A', 'B', 'C', 'D')),
  explanation TEXT,
  difficulty TEXT CHECK (difficulty IN ('easy', 'medium', 'hard')),
  
  -- Lifecycle state
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'in_review', 'approved', 'published', 'archived')),
  
  -- Assignment (for published versions)
  quiz_id UUID REFERENCES public.quizzes(id) ON DELETE SET NULL,
  exam_id UUID REFERENCES public.exams(id) ON DELETE SET NULL,
  
  -- Metadata
  created_by UUID NOT NULL REFERENCES auth.users(id),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  submitted_at TIMESTAMPTZ, -- When submitted for review
  reviewed_at TIMESTAMPTZ, -- When approved/rejected
  reviewed_by UUID REFERENCES auth.users(id),
  published_at TIMESTAMPTZ, -- When published
  published_by UUID REFERENCES auth.users(id),
  
  -- Review feedback
  review_comment TEXT,
  
  CONSTRAINT one_parent_only CHECK (
    (quiz_id IS NOT NULL AND exam_id IS NULL) OR 
    (quiz_id IS NULL AND exam_id IS NOT NULL) OR 
    (quiz_id IS NULL AND exam_id IS NULL AND status != 'published')
  )
);

CREATE INDEX idx_question_versions_status ON public.question_versions(status);
CREATE INDEX idx_question_versions_created_by ON public.question_versions(created_by);
CREATE INDEX idx_question_versions_question_id ON public.question_versions(question_id);

COMMENT ON TABLE public.question_versions IS 'Immutable version history for questions. Each edit creates a new version.';

-- =============================================================================
-- PART 2: AUDIT LOG (MODULE 5)
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.admin_audit_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- Actor information
  actor_id UUID NOT NULL REFERENCES auth.users(id),
  actual_role TEXT NOT NULL, -- Role at time of action
  effective_role TEXT, -- If acting on behalf of another role
  
  -- Action details
  action_type TEXT NOT NULL, -- 'create', 'update', 'delete', 'publish', 'ban', 'coin_adjust', etc.
  entity_type TEXT NOT NULL, -- 'question', 'user', 'coin_ledger', etc.
  entity_id UUID,
  
  -- State tracking
  before_state JSONB,
  after_state JSONB,
  
  -- Required justification
  reason TEXT NOT NULL,
  reference TEXT, -- Ticket ID, incident ID, etc.
  
  -- Metadata
  ip_address INET,
  user_agent TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_audit_log_actor ON public.admin_audit_log(actor_id);
CREATE INDEX idx_audit_log_entity ON public.admin_audit_log(entity_type, entity_id);
CREATE INDEX idx_audit_log_created_at ON public.admin_audit_log(created_at DESC);

COMMENT ON TABLE public.admin_audit_log IS 'Immutable audit trail for all admin actions. Evidence-grade logging.';

-- =============================================================================
-- PART 3: OPS & ABUSE TABLES (MODULE 3 & 4)
-- =============================================================================

-- User restrictions (bans, warnings)
CREATE TABLE IF NOT EXISTS public.user_restrictions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  
  restriction_type TEXT NOT NULL CHECK (restriction_type IN ('warning', 'temp_ban', 'permanent_ban', 'coin_freeze')),
  
  -- Duration (NULL for permanent)
  starts_at TIMESTAMPTZ DEFAULT NOW(),
  ends_at TIMESTAMPTZ,
  
  -- Justification (mandatory)
  reason TEXT NOT NULL,
  incident_id UUID, -- Reference to abuse case
  
  -- Metadata
  created_by UUID NOT NULL REFERENCES auth.users(id),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  revoked_at TIMESTAMPTZ,
  revoked_by UUID REFERENCES auth.users(id),
  revoke_reason TEXT
);

CREATE INDEX idx_user_restrictions_user ON public.user_restrictions(user_id);

COMMENT ON TABLE public.user_restrictions IS 'User bans, warnings, and restrictions. All require justification. Check is_active in queries: revoked_at IS NULL AND (ends_at IS NULL OR ends_at > NOW())';


-- Abuse reports and investigations
CREATE TABLE IF NOT EXISTS public.abuse_cases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- Subject
  reported_user_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  reported_content_type TEXT, -- 'question', 'attempt', 'profile', etc.
  reported_content_id UUID,
  
  -- Source
  source TEXT NOT NULL CHECK (source IN ('user_report', 'automated', 'ops_flag', 'analytics')),
  reporter_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  
  -- Case details
  case_type TEXT NOT NULL, -- 'cheating', 'abuse', 'spam', 'content_error', etc.
  description TEXT NOT NULL,
  evidence JSONB, -- Screenshots, logs, patterns, etc.
  
  -- Investigation
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'investigating', 'resolved', 'dismissed')),
  assigned_to UUID REFERENCES auth.users(id),
  investigation_notes TEXT,
  
  -- Resolution
  resolution TEXT,
  resolved_at TIMESTAMPTZ,
  resolved_by UUID REFERENCES auth.users(id),
  action_taken TEXT, -- 'banned', 'warned', 'content_removed', 'no_action', etc.
  
  -- Metadata
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_abuse_cases_status ON public.abuse_cases(status);
CREATE INDEX idx_abuse_cases_reported_user ON public.abuse_cases(reported_user_id);
CREATE INDEX idx_abuse_cases_assigned_to ON public.abuse_cases(assigned_to);

COMMENT ON TABLE public.abuse_cases IS 'Abuse reports, investigations, and resolutions. Read-only investigation workspace.';

-- Content incidents (post-publish emergencies)
CREATE TABLE IF NOT EXISTS public.content_incidents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- Affected content
  content_type TEXT NOT NULL, -- 'question', 'quiz', 'exam'
  content_id UUID NOT NULL,
  version_id UUID REFERENCES public.question_versions(id),
  
  -- Incident details
  incident_type TEXT NOT NULL, -- 'wrong_answer', 'offensive_content', 'technical_error', etc.
  severity TEXT NOT NULL CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  description TEXT NOT NULL,
  
  -- Response
  status TEXT NOT NULL DEFAULT 'reported' CHECK (status IN ('reported', 'acknowledged', 'disabled', 'fixed', 'dismissed')),
  disabled_at TIMESTAMPTZ, -- Emergency takedown timestamp
  disabled_by UUID REFERENCES auth.users(id),
  
  -- Resolution
  resolution_notes TEXT,
  resolved_at TIMESTAMPTZ,
  resolved_by UUID REFERENCES auth.users(id),
  
  -- Metadata
  reported_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_content_incidents_status ON public.content_incidents(status);
CREATE INDEX idx_content_incidents_content ON public.content_incidents(content_type, content_id);

COMMENT ON TABLE public.content_incidents IS 'Post-publish content emergencies. Immediate disable, no edits.';

-- =============================================================================
-- PART 4: RLS POLICIES
-- =============================================================================

-- Enable RLS on all new tables
ALTER TABLE public.question_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_restrictions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.abuse_cases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.content_incidents ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- QUESTION_VERSIONS RLS
-- ============================================================

-- Authors: Can view own drafts, create drafts, edit own drafts
CREATE POLICY "Authors can view own drafts" ON public.question_versions
FOR SELECT TO authenticated
USING (
  status = 'draft' AND created_by = auth.uid() AND
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('author', 'content_admin', 'super_admin'))
);

CREATE POLICY "Authors can create drafts" ON public.question_versions
FOR INSERT TO authenticated
WITH CHECK (
  status = 'draft' AND created_by = auth.uid() AND
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('author', 'content_admin', 'super_admin'))
);

CREATE POLICY "Authors can update own drafts" ON public.question_versions
FOR UPDATE TO authenticated
USING (
  status = 'draft' AND created_by = auth.uid() AND
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('author', 'content_admin', 'super_admin'))
)
WITH CHECK (
  status IN ('draft', 'in_review') AND created_by = auth.uid()
);

-- Reviewers: Can view in_review, update status to approved/draft
CREATE POLICY "Reviewers can view in_review" ON public.question_versions
FOR SELECT TO authenticated
USING (
  status = 'in_review' AND
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('reviewer', 'content_admin', 'super_admin'))
);

CREATE POLICY "Reviewers can approve or reject" ON public.question_versions
FOR UPDATE TO authenticated
USING (
  status = 'in_review' AND
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('reviewer', 'content_admin', 'super_admin'))
)
WITH CHECK (
  status IN ('approved', 'draft') AND
  reviewed_by = auth.uid()
);

-- Content Admins: Can view approved, publish
CREATE POLICY "Admins can view approved" ON public.question_versions
FOR SELECT TO authenticated
USING (
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('content_admin', 'super_admin'))
);

CREATE POLICY "Admins can publish" ON public.question_versions
FOR UPDATE TO authenticated
USING (
  status = 'approved' AND
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('content_admin', 'super_admin'))
)
WITH CHECK (
  status = 'published' AND published_by = auth.uid()
);

-- ============================================================
-- AUDIT_LOG RLS (Read-only for ops/super admins)
-- ============================================================

CREATE POLICY "Ops admins can read audit log" ON public.admin_audit_log
FOR SELECT TO authenticated
USING (
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('ops_admin', 'super_admin'))
);

CREATE POLICY "System can write audit log" ON public.admin_audit_log
FOR INSERT TO authenticated
WITH CHECK (actor_id = auth.uid());

-- ============================================================
-- USER_RESTRICTIONS RLS
-- ============================================================

CREATE POLICY "Ops admins can manage restrictions" ON public.user_restrictions
FOR ALL TO authenticated
USING (
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('ops_admin', 'super_admin'))
)
WITH CHECK (
  created_by = auth.uid()
);

-- Users can view their own restrictions
CREATE POLICY "Users can view own restrictions" ON public.user_restrictions
FOR SELECT TO authenticated
USING (user_id = auth.uid());

-- ============================================================
-- ABUSE_CASES RLS
-- ============================================================

CREATE POLICY "Ops admins can manage abuse cases" ON public.abuse_cases
FOR ALL TO authenticated
USING (
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('ops_admin', 'super_admin'))
);

-- ============================================================
-- CONTENT_INCIDENTS RLS
-- ============================================================

CREATE POLICY "Admins can manage incidents" ON public.content_incidents
FOR ALL TO authenticated
USING (
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('content_admin', 'ops_admin', 'super_admin'))
);

-- =============================================================================
-- PART 5: RPC FUNCTIONS (STATE TRANSITIONS)
-- =============================================================================

-- Submit draft for review (Author action)
CREATE OR REPLACE FUNCTION submit_for_review(version_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_role TEXT;
  v_result JSONB;
BEGIN
  -- Check role
  SELECT role INTO v_role FROM public.user_roles 
  WHERE user_id = auth.uid() AND role IN ('author', 'content_admin', 'super_admin')
  LIMIT 1;
  
  IF v_role IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
  END IF;
  
  -- Update version
  UPDATE public.question_versions
  SET status = 'in_review', submitted_at = NOW()
  WHERE id = version_id AND created_by = auth.uid() AND status = 'draft';
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Version not found or not in draft status');
  END IF;
  
  -- Audit log
  INSERT INTO public.admin_audit_log (actor_id, actual_role, action_type, entity_type, entity_id, reason)
  VALUES (auth.uid(), v_role, 'submit_for_review', 'question_version', version_id, 'Author submitted for review');
  
  RETURN jsonb_build_object('success', true);
END;
$$;

-- Approve question (Reviewer action)
CREATE OR REPLACE FUNCTION approve_question(version_id UUID, review_comment TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_role TEXT;
BEGIN
  -- Check role
  SELECT role INTO v_role FROM public.user_roles 
  WHERE user_id = auth.uid() AND role IN ('reviewer', 'content_admin', 'super_admin')
  LIMIT 1;
  
  IF v_role IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
  END IF;
  
  -- Update version
  UPDATE public.question_versions
  SET 
    status = 'approved',
    reviewed_at = NOW(),
    reviewed_by = auth.uid(),
    review_comment = approve_question.review_comment
  WHERE id = version_id AND status = 'in_review';
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Version not found or not in review');
  END IF;
  
  -- Audit log
  INSERT INTO public.admin_audit_log (actor_id, actual_role, action_type, entity_type, entity_id, reason)
  VALUES (auth.uid(), v_role, 'approve', 'question_version', version_id, COALESCE(review_comment, 'Approved by reviewer'));
  
  RETURN jsonb_build_object('success', true);
END;
$$;

-- Reject question (Reviewer action)
CREATE OR REPLACE FUNCTION reject_question(version_id UUID, review_comment TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_role TEXT;
BEGIN
  -- Check role
  SELECT role INTO v_role FROM public.user_roles 
  WHERE user_id = auth.uid() AND role IN ('reviewer', 'content_admin', 'super_admin')
  LIMIT 1;
  
  IF v_role IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
  END IF;
  
  IF review_comment IS NULL OR review_comment = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Review comment is mandatory for rejection');
  END IF;
  
  -- Update version
  UPDATE public.question_versions
  SET 
    status = 'draft',
    reviewed_at = NOW(),
    reviewed_by = auth.uid(),
    review_comment = reject_question.review_comment
  WHERE id = version_id AND status = 'in_review';
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Version not found or not in review');
  END IF;
  
  -- Audit log
  INSERT INTO public.admin_audit_log (actor_id, actual_role, action_type, entity_type, entity_id, reason)
  VALUES (auth.uid(), v_role, 'reject', 'question_version', version_id, review_comment);
  
  RETURN jsonb_build_object('success', true);
END;
$$;

-- Publish question (Content Admin action)
CREATE OR REPLACE FUNCTION publish_question(version_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_role TEXT;
  v_version RECORD;
  v_new_question_id UUID;
BEGIN
  -- Check role
  SELECT role INTO v_role FROM public.user_roles 
  WHERE user_id = auth.uid() AND role IN ('content_admin', 'super_admin')
  LIMIT 1;
  
  IF v_role IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
  END IF;
  
  -- Get version
  SELECT * INTO v_version FROM public.question_versions WHERE id = version_id AND status = 'approved';
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Version not found or not approved');
  END IF;
  
  -- Validate parent assignment
  IF v_version.quiz_id IS NULL AND v_version.exam_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Must assign to quiz or exam before publishing');
  END IF;
  
  -- Copy to live questions table
  INSERT INTO public.questions (
    question_text, option_a, option_b, option_c, option_d, 
    correct_option, explanation, quiz_id, exam_id
  )
  VALUES (
    v_version.question_text, v_version.option_a, v_version.option_b, 
    v_version.option_c, v_version.option_d, v_version.correct_option,
    v_version.explanation, v_version.quiz_id, v_version.exam_id
  )
  RETURNING id INTO v_new_question_id;
  
  -- Update version to published
  UPDATE public.question_versions
  SET 
    status = 'published',
    published_at = NOW(),
    published_by = auth.uid(),
    question_id = v_new_question_id
  WHERE id = version_id;
  
  -- Audit log
  INSERT INTO public.admin_audit_log (
    actor_id, actual_role, action_type, entity_type, entity_id, 
    reason, after_state
  )
  VALUES (
    auth.uid(), v_role, 'publish', 'question', v_new_question_id,
    'Published from version ' || version_id,
    jsonb_build_object('version_id', version_id, 'question_id', v_new_question_id)
  );
  
  RETURN jsonb_build_object('success', true, 'question_id', v_new_question_id);
END;
$$;

-- =============================================================================
-- PART 6: HELPER FUNCTIONS
-- =============================================================================

-- Check if user has specific role
CREATE OR REPLACE FUNCTION has_role(check_role TEXT)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles 
    WHERE user_id = auth.uid() AND role = check_role
  );
$$;

-- Get user's highest role (for UI display)
CREATE OR REPLACE FUNCTION get_user_role()
RETURNS TEXT
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT role FROM public.user_roles 
  WHERE user_id = auth.uid()
  ORDER BY 
    CASE role
      WHEN 'super_admin' THEN 1
      WHEN 'ops_admin' THEN 2
      WHEN 'content_admin' THEN 3
      WHEN 'reviewer' THEN 4
      WHEN 'author' THEN 5
      WHEN 'admin' THEN 6
      WHEN 'moderator' THEN 7
      ELSE 99
    END
  LIMIT 1;
$$;

-- =============================================================================
-- PART 7: GRANTS
-- =============================================================================

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT ALL ON public.question_versions TO authenticated;
GRANT ALL ON public.admin_audit_log TO authenticated;
GRANT ALL ON public.user_restrictions TO authenticated;
GRANT ALL ON public.abuse_cases TO authenticated;
GRANT ALL ON public.content_incidents TO authenticated;

GRANT EXECUTE ON FUNCTION submit_for_review TO authenticated;
GRANT EXECUTE ON FUNCTION approve_question TO authenticated;
GRANT EXECUTE ON FUNCTION reject_question TO authenticated;
GRANT EXECUTE ON FUNCTION publish_question TO authenticated;
GRANT EXECUTE ON FUNCTION has_role TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_role TO authenticated;

-- =============================================================================
-- END OF MIGRATION
-- =============================================================================
