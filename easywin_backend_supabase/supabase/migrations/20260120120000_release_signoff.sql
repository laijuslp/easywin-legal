-- ============================================================================
-- EASYWIN 1.0 - RELEASE SIGN-OFF & AUDIT TRAIL
-- Immutable release tracking with multi-stakeholder approval
-- ============================================================================

-- PART 1: RELEASE REGISTRY
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.releases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    release_version TEXT NOT NULL UNIQUE, -- e.g., '1.0.0', '1.0.1'
    release_type TEXT NOT NULL CHECK (release_type IN ('major', 'minor', 'patch', 'hotfix')),
    release_name TEXT, -- Optional marketing name
    
    -- SSOT Snapshots
    ssot_version_snapshot JSONB NOT NULL, -- All SSOT versions at release time
    rule_snapshots JSONB NOT NULL, -- Business rules snapshot
    content_hashes JSONB NOT NULL, -- Question/quiz content hashes
    flag_states JSONB NOT NULL, -- Feature flag states
    
    -- Approval workflow
    status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'pending_approval', 'approved', 'deployed', 'rolled_back')),
    
    tech_lead_approved BOOLEAN DEFAULT false,
    tech_lead_approved_by UUID REFERENCES auth.users(id),
    tech_lead_approved_at TIMESTAMPTZ,
    tech_lead_notes TEXT,
    
    qa_lead_approved BOOLEAN DEFAULT false,
    qa_lead_approved_by UUID REFERENCES auth.users(id),
    qa_lead_approved_at TIMESTAMPTZ,
    qa_lead_notes TEXT,
    qa_gate_results JSONB, -- Results from run_qa_gates()
    
    product_owner_approved BOOLEAN DEFAULT false,
    product_owner_approved_by UUID REFERENCES auth.users(id),
    product_owner_approved_at TIMESTAMPTZ,
    product_owner_notes TEXT,
    
    ops_admin_approved BOOLEAN DEFAULT false,
    ops_admin_approved_by UUID REFERENCES auth.users(id),
    ops_admin_approved_at TIMESTAMPTZ,
    ops_admin_notes TEXT,
    rollback_plan TEXT,
    
    -- Deployment tracking
    deployed_at TIMESTAMPTZ,
    deployed_by UUID REFERENCES auth.users(id),
    rollout_timeline JSONB, -- Feature flag rollout schedule
    
    -- Rollback
    rolled_back_at TIMESTAMPTZ,
    rolled_back_by UUID REFERENCES auth.users(id),
    rollback_reason TEXT,
    
    -- Metadata
    created_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID REFERENCES auth.users(id),
    
    CONSTRAINT all_approvals_for_deployment CHECK (
        (status != 'deployed') OR 
        (tech_lead_approved AND qa_lead_approved AND product_owner_approved AND ops_admin_approved)
    )
);

CREATE INDEX idx_releases_version ON public.releases(release_version);
CREATE INDEX idx_releases_status ON public.releases(status);
CREATE INDEX idx_releases_deployed ON public.releases(deployed_at DESC) WHERE deployed_at IS NOT NULL;

-- PART 2: RELEASE CHECKLIST
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.release_checklist (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    release_id UUID NOT NULL REFERENCES public.releases(id) ON DELETE CASCADE,
    checklist_item TEXT NOT NULL,
    category TEXT NOT NULL CHECK (category IN ('ssot', 'qa', 'content', 'infrastructure', 'documentation')),
    is_required BOOLEAN DEFAULT true,
    is_completed BOOLEAN DEFAULT false,
    completed_by UUID REFERENCES auth.users(id),
    completed_at TIMESTAMPTZ,
    notes TEXT,
    evidence_url TEXT, -- Link to test results, docs, etc.
    
    CONSTRAINT unique_release_item UNIQUE(release_id, checklist_item)
);

CREATE INDEX idx_release_checklist_release ON public.release_checklist(release_id);

-- PART 3: RELEASE ARTIFACTS
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.release_artifacts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    release_id UUID NOT NULL REFERENCES public.releases(id) ON DELETE CASCADE,
    artifact_type TEXT NOT NULL CHECK (artifact_type IN ('apk', 'aab', 'migration_sql', 'backup', 'config', 'documentation')),
    artifact_name TEXT NOT NULL,
    artifact_url TEXT, -- Storage URL
    artifact_hash TEXT NOT NULL, -- SHA-256
    file_size_bytes BIGINT,
    uploaded_at TIMESTAMPTZ DEFAULT NOW(),
    uploaded_by UUID REFERENCES auth.users(id),
    
    CONSTRAINT valid_file_size CHECK (file_size_bytes IS NULL OR file_size_bytes > 0)
);

CREATE INDEX idx_release_artifacts_release ON public.release_artifacts(release_id);

-- PART 4: RELEASE FUNCTIONS
-- ============================================================================

-- Function: Create release
CREATE OR REPLACE FUNCTION public.create_release(
    p_release_version TEXT,
    p_release_type TEXT,
    p_release_name TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    release_id UUID;
    ssot_snapshot JSONB;
    rule_snapshot JSONB;
    content_hash JSONB;
    flag_snapshot JSONB;
BEGIN
    -- Capture SSOT versions
    SELECT jsonb_object_agg(domain, data) INTO ssot_snapshot
    FROM public.ssot_versions
    WHERE is_active = true;
    
    -- Capture business rules (from SSOT)
    SELECT data INTO rule_snapshot
    FROM public.ssot_versions
    WHERE domain = 'scoring_rules' AND is_active = true;
    
    -- Capture content hashes
    SELECT jsonb_build_object(
        'questions', COUNT(*),
        'quizzes', (SELECT COUNT(*) FROM public.assessments WHERE type = 'quiz'),
        'exams', (SELECT COUNT(*) FROM public.assessments WHERE type = 'exam')
    ) INTO content_hash;
    
    -- Capture feature flag states
    SELECT jsonb_object_agg(flag_key, jsonb_build_object(
        'enabled', is_enabled,
        'rollout_percentage', rollout_percentage,
        'kill_switch', kill_switch_activated
    )) INTO flag_snapshot
    FROM public.feature_flags;
    
    -- Create release
    INSERT INTO public.releases (
        release_version,
        release_type,
        release_name,
        ssot_version_snapshot,
        rule_snapshots,
        content_hashes,
        flag_states,
        created_by
    ) VALUES (
        p_release_version,
        p_release_type,
        p_release_name,
        ssot_snapshot,
        rule_snapshot,
        content_hash,
        flag_snapshot,
        auth.uid()
    ) RETURNING id INTO release_id;
    
    -- Create default checklist
    INSERT INTO public.release_checklist (release_id, checklist_item, category, is_required) VALUES
        (release_id, 'SSOT version bumped where needed', 'ssot', true),
        (release_id, 'All QA gates passed', 'qa', true),
        (release_id, 'Golden snapshots validated', 'qa', true),
        (release_id, 'Content safety checks passed', 'content', true),
        (release_id, 'Migration tested on staging', 'infrastructure', true),
        (release_id, 'Rollback plan documented', 'infrastructure', true),
        (release_id, 'Feature flags configured', 'infrastructure', true),
        (release_id, 'Release notes published', 'documentation', true);
    
    RETURN jsonb_build_object(
        'success', true,
        'release_id', release_id,
        'release_version', p_release_version,
        'checklist_items', 8
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Approve release
CREATE OR REPLACE FUNCTION public.approve_release(
    p_release_id UUID,
    p_approver_role TEXT, -- 'tech_lead', 'qa_lead', 'product_owner', 'ops_admin'
    p_notes TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    rel RECORD;
    all_approved BOOLEAN;
BEGIN
    SELECT * INTO rel
    FROM public.releases
    WHERE id = p_release_id
      AND status IN ('draft', 'pending_approval');
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Release not found or already processed');
    END IF;
    
    -- Update approval based on role
    CASE p_approver_role
        WHEN 'tech_lead' THEN
            UPDATE public.releases
            SET tech_lead_approved = true,
                tech_lead_approved_by = auth.uid(),
                tech_lead_approved_at = NOW(),
                tech_lead_notes = p_notes
            WHERE id = p_release_id;
        
        WHEN 'qa_lead' THEN
            -- Run QA gates and store results
            DECLARE
                qa_results JSONB;
            BEGIN
                SELECT public.run_qa_gates('release_approval', p_release_id::TEXT) INTO qa_results;
                
                UPDATE public.releases
                SET qa_lead_approved = true,
                    qa_lead_approved_by = auth.uid(),
                    qa_lead_approved_at = NOW(),
                    qa_lead_notes = p_notes,
                    qa_gate_results = qa_results
                WHERE id = p_release_id;
            END;
        
        WHEN 'product_owner' THEN
            UPDATE public.releases
            SET product_owner_approved = true,
                product_owner_approved_by = auth.uid(),
                product_owner_approved_at = NOW(),
                product_owner_notes = p_notes
            WHERE id = p_release_id;
        
        WHEN 'ops_admin' THEN
            UPDATE public.releases
            SET ops_admin_approved = true,
                ops_admin_approved_by = auth.uid(),
                ops_admin_approved_at = NOW(),
                ops_admin_notes = p_notes
            WHERE id = p_release_id;
        
        ELSE
            RETURN jsonb_build_object('success', false, 'error', 'Invalid approver role');
    END CASE;
    
    -- Check if all approvals complete
    SELECT 
        tech_lead_approved AND qa_lead_approved AND 
        product_owner_approved AND ops_admin_approved
    INTO all_approved
    FROM public.releases
    WHERE id = p_release_id;
    
    IF all_approved THEN
        UPDATE public.releases
        SET status = 'approved'
        WHERE id = p_release_id;
        
        RETURN jsonb_build_object(
            'success', true,
            'status', 'approved',
            'message', 'All approvals complete. Ready for deployment.'
        );
    ELSE
        UPDATE public.releases
        SET status = 'pending_approval'
        WHERE id = p_release_id AND status = 'draft';
        
        RETURN jsonb_build_object(
            'success', true,
            'status', 'pending_approval',
            'message', 'Approval recorded. Waiting for remaining approvals.'
        );
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Deploy release
CREATE OR REPLACE FUNCTION public.deploy_release(p_release_id UUID)
RETURNS JSONB AS $$
DECLARE
    rel RECORD;
    incomplete_items INTEGER;
BEGIN
    SELECT * INTO rel
    FROM public.releases
    WHERE id = p_release_id
      AND status = 'approved';
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Release not approved');
    END IF;
    
    -- Check all required checklist items are complete
    SELECT COUNT(*) INTO incomplete_items
    FROM public.release_checklist
    WHERE release_id = p_release_id
      AND is_required = true
      AND is_completed = false;
    
    IF incomplete_items > 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Incomplete checklist items',
            'incomplete_count', incomplete_items
        );
    END IF;
    
    -- Mark as deployed
    UPDATE public.releases
    SET status = 'deployed',
        deployed_at = NOW(),
        deployed_by = auth.uid()
    WHERE id = p_release_id;
    
    RETURN jsonb_build_object(
        'success', true,
        'release_version', rel.release_version,
        'deployed_at', NOW(),
        'message', 'Release deployed successfully'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 5: RLS POLICIES
-- ============================================================================

ALTER TABLE public.releases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.release_checklist ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.release_artifacts ENABLE ROW LEVEL SECURITY;

-- All admins can view releases
CREATE POLICY "Admins view releases"
    ON public.releases FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid()
              AND role IN ('content_admin', 'ops_admin', 'super_admin')
        )
    );

-- Only super admins can create releases
CREATE POLICY "Super admins create releases"
    ON public.releases FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid() AND role = 'super_admin'
        )
    );

-- Admins can view checklists
CREATE POLICY "Admins view checklists"
    ON public.release_checklist FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid()
              AND role IN ('content_admin', 'ops_admin', 'super_admin')
        )
    );

-- Admins can view artifacts
CREATE POLICY "Admins view artifacts"
    ON public.release_artifacts FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid()
              AND role IN ('ops_admin', 'super_admin')
        )
    );

COMMENT ON TABLE public.releases IS 'Immutable release tracking with multi-stakeholder approval.';
COMMENT ON TABLE public.release_checklist IS 'Pre-deployment checklist for each release.';
COMMENT ON TABLE public.release_artifacts IS 'Build artifacts and documentation for releases.';
COMMENT ON FUNCTION public.create_release IS 'Create new release with SSOT and content snapshots.';
COMMENT ON FUNCTION public.approve_release IS 'Approve release by role (tech_lead, qa_lead, product_owner, ops_admin).';
COMMENT ON FUNCTION public.deploy_release IS 'Deploy approved release after checklist validation.';
