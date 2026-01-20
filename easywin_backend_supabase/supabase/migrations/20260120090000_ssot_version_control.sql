-- ============================================================================
-- EASYWIN 1.0 - SSOT VERSION CONTROL & CHANGE MANAGEMENT
-- Immutable versioning for all business rules, constants, and configurations
-- ============================================================================

-- PART 1: SSOT REGISTRY (AUTHORITATIVE SOURCE TRACKING)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.ssot_registry (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    domain TEXT NOT NULL UNIQUE, -- e.g., 'coin_economy', 'scoring_rules', 'premium_access'
    description TEXT NOT NULL,
    current_version INTEGER NOT NULL DEFAULT 1,
    schema_definition JSONB NOT NULL, -- Structure of the SSOT data
    last_modified_at TIMESTAMPTZ DEFAULT NOW(),
    last_modified_by UUID REFERENCES auth.users(id),
    is_locked BOOLEAN DEFAULT false, -- Prevent changes without unlock
    
    CONSTRAINT valid_version CHECK (current_version > 0)
);

-- Insert SSOT domains
INSERT INTO public.ssot_registry (domain, description, schema_definition) VALUES
    ('coin_economy', 'All coin earning, spending, and pricing rules', 
     '{"quiz_completion": "integer", "ad_watch": "integer", "daily_bonus": "integer", "hint_cost": "integer"}'::jsonb),
    
    ('scoring_rules', 'Quiz scoring, time bonuses, streak multipliers',
     '{"base_points": "integer", "time_bonus_multiplier": "numeric", "streak_bonus": "integer"}'::jsonb),
    
    ('premium_access', 'Premium unlock conditions and benefits',
     '{"unlock_threshold": "integer", "benefits": "array", "duration_days": "integer"}'::jsonb),
    
    ('retention_policies', 'Data retention periods for all domains',
     '{"domain": "text", "retention_days": "integer", "deletion_type": "text"}'::jsonb),
    
    ('quiz_constraints', 'Quiz time limits, retry limits, question counts',
     '{"max_time_seconds": "integer", "max_retries": "integer", "questions_per_quiz": "integer"}'::jsonb),
    
    ('offline_sync', 'Offline mode rules and sync behavior',
     '{"max_offline_quizzes": "integer", "sync_interval_seconds": "integer", "conflict_resolution": "text"}'::jsonb)
ON CONFLICT (domain) DO NOTHING;

-- PART 2: SSOT VERSIONS (IMMUTABLE HISTORY)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.ssot_versions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    domain TEXT NOT NULL REFERENCES public.ssot_registry(domain) ON DELETE CASCADE,
    version INTEGER NOT NULL,
    data JSONB NOT NULL, -- The actual SSOT values
    change_summary TEXT NOT NULL,
    changed_by UUID NOT NULL REFERENCES auth.users(id),
    approved_by UUID REFERENCES auth.users(id),
    approved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    is_active BOOLEAN DEFAULT false, -- Only one active version per domain
    
    CONSTRAINT unique_domain_version UNIQUE(domain, version),
    CONSTRAINT valid_version CHECK (version > 0)
);

CREATE INDEX idx_ssot_versions_domain ON public.ssot_versions(domain, version DESC);
CREATE INDEX idx_ssot_versions_active ON public.ssot_versions(domain) WHERE is_active = true;

-- PART 3: SSOT CHANGE REQUESTS (APPROVAL WORKFLOW)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.ssot_change_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    domain TEXT NOT NULL REFERENCES public.ssot_registry(domain),
    proposed_version INTEGER NOT NULL,
    proposed_data JSONB NOT NULL,
    change_summary TEXT NOT NULL,
    impact_assessment TEXT NOT NULL, -- What will break/change
    requested_by UUID NOT NULL REFERENCES auth.users(id),
    requested_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- Approval workflow
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected', 'deployed')),
    tech_lead_approved BOOLEAN DEFAULT false,
    tech_lead_approved_by UUID REFERENCES auth.users(id),
    tech_lead_approved_at TIMESTAMPTZ,
    
    qa_lead_approved BOOLEAN DEFAULT false,
    qa_lead_approved_by UUID REFERENCES auth.users(id),
    qa_lead_approved_at TIMESTAMPTZ,
    
    product_owner_approved BOOLEAN DEFAULT false,
    product_owner_approved_by UUID REFERENCES auth.users(id),
    product_owner_approved_at TIMESTAMPTZ,
    
    ops_admin_approved BOOLEAN DEFAULT false,
    ops_admin_approved_by UUID REFERENCES auth.users(id),
    ops_admin_approved_at TIMESTAMPTZ,
    
    rejection_reason TEXT,
    deployed_at TIMESTAMPTZ,
    
    CONSTRAINT all_approvals_required CHECK (
        (status != 'approved') OR 
        (tech_lead_approved AND qa_lead_approved AND product_owner_approved AND ops_admin_approved)
    )
);

CREATE INDEX idx_ssot_change_requests_status ON public.ssot_change_requests(status);
CREATE INDEX idx_ssot_change_requests_domain ON public.ssot_change_requests(domain, requested_at DESC);

-- PART 4: SSOT DEPLOYMENT LOG (IMMUTABLE AUDIT)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.ssot_deployment_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    domain TEXT NOT NULL,
    from_version INTEGER,
    to_version INTEGER NOT NULL,
    deployed_by UUID NOT NULL REFERENCES auth.users(id),
    deployed_at TIMESTAMPTZ DEFAULT NOW(),
    rollback_available BOOLEAN DEFAULT true,
    rollback_executed BOOLEAN DEFAULT false,
    rollback_at TIMESTAMPTZ,
    deployment_summary JSONB NOT NULL,
    
    CONSTRAINT valid_version_change CHECK (to_version > 0 AND (from_version IS NULL OR to_version > from_version))
);

CREATE INDEX idx_ssot_deployment_log_domain ON public.ssot_deployment_log(domain, deployed_at DESC);

-- PART 5: SSOT FUNCTIONS
-- ============================================================================

-- Function: Get current SSOT for a domain
CREATE OR REPLACE FUNCTION public.get_ssot(p_domain TEXT)
RETURNS JSONB AS $$
DECLARE
    ssot_data JSONB;
BEGIN
    SELECT data INTO ssot_data
    FROM public.ssot_versions
    WHERE domain = p_domain
      AND is_active = true;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No active SSOT found for domain: %', p_domain;
    END IF;
    
    RETURN ssot_data;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Request SSOT change
CREATE OR REPLACE FUNCTION public.request_ssot_change(
    p_domain TEXT,
    p_proposed_data JSONB,
    p_change_summary TEXT,
    p_impact_assessment TEXT
)
RETURNS JSONB AS $$
DECLARE
    current_version INTEGER;
    new_version INTEGER;
    request_id UUID;
BEGIN
    -- Get current version
    SELECT version INTO current_version
    FROM public.ssot_versions
    WHERE domain = p_domain
      AND is_active = true;
    
    IF NOT FOUND THEN
        current_version := 0;
    END IF;
    
    new_version := current_version + 1;
    
    -- Create change request
    INSERT INTO public.ssot_change_requests (
        domain,
        proposed_version,
        proposed_data,
        change_summary,
        impact_assessment,
        requested_by
    ) VALUES (
        p_domain,
        new_version,
        p_proposed_data,
        p_change_summary,
        p_impact_assessment,
        auth.uid()
    ) RETURNING id INTO request_id;
    
    RETURN jsonb_build_object(
        'success', true,
        'request_id', request_id,
        'proposed_version', new_version,
        'requires_approvals', ARRAY['tech_lead', 'qa_lead', 'product_owner', 'ops_admin']
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Approve SSOT change
CREATE OR REPLACE FUNCTION public.approve_ssot_change(
    p_request_id UUID,
    p_approver_role TEXT -- 'tech_lead', 'qa_lead', 'product_owner', 'ops_admin'
)
RETURNS JSONB AS $$
DECLARE
    req RECORD;
    all_approved BOOLEAN;
BEGIN
    -- Get request
    SELECT * INTO req
    FROM public.ssot_change_requests
    WHERE id = p_request_id
      AND status = 'pending';
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Request not found or already processed');
    END IF;
    
    -- Update approval based on role
    CASE p_approver_role
        WHEN 'tech_lead' THEN
            UPDATE public.ssot_change_requests
            SET tech_lead_approved = true,
                tech_lead_approved_by = auth.uid(),
                tech_lead_approved_at = NOW()
            WHERE id = p_request_id;
        
        WHEN 'qa_lead' THEN
            UPDATE public.ssot_change_requests
            SET qa_lead_approved = true,
                qa_lead_approved_by = auth.uid(),
                qa_lead_approved_at = NOW()
            WHERE id = p_request_id;
        
        WHEN 'product_owner' THEN
            UPDATE public.ssot_change_requests
            SET product_owner_approved = true,
                product_owner_approved_by = auth.uid(),
                product_owner_approved_at = NOW()
            WHERE id = p_request_id;
        
        WHEN 'ops_admin' THEN
            UPDATE public.ssot_change_requests
            SET ops_admin_approved = true,
                ops_admin_approved_by = auth.uid(),
                ops_admin_approved_at = NOW()
            WHERE id = p_request_id;
        
        ELSE
            RETURN jsonb_build_object('success', false, 'error', 'Invalid approver role');
    END CASE;
    
    -- Check if all approvals are complete
    SELECT 
        tech_lead_approved AND qa_lead_approved AND 
        product_owner_approved AND ops_admin_approved
    INTO all_approved
    FROM public.ssot_change_requests
    WHERE id = p_request_id;
    
    IF all_approved THEN
        UPDATE public.ssot_change_requests
        SET status = 'approved'
        WHERE id = p_request_id;
        
        RETURN jsonb_build_object(
            'success', true,
            'status', 'approved',
            'message', 'All approvals complete. Ready for deployment.'
        );
    ELSE
        RETURN jsonb_build_object(
            'success', true,
            'status', 'pending',
            'message', 'Approval recorded. Waiting for remaining approvals.'
        );
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Deploy approved SSOT change
CREATE OR REPLACE FUNCTION public.deploy_ssot_change(p_request_id UUID)
RETURNS JSONB AS $$
DECLARE
    req RECORD;
    current_version INTEGER;
BEGIN
    -- Get approved request
    SELECT * INTO req
    FROM public.ssot_change_requests
    WHERE id = p_request_id
      AND status = 'approved';
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Request not found or not approved');
    END IF;
    
    -- Get current version
    SELECT version INTO current_version
    FROM public.ssot_versions
    WHERE domain = req.domain
      AND is_active = true;
    
    -- Deactivate current version
    UPDATE public.ssot_versions
    SET is_active = false
    WHERE domain = req.domain
      AND is_active = true;
    
    -- Insert new version
    INSERT INTO public.ssot_versions (
        domain,
        version,
        data,
        change_summary,
        changed_by,
        approved_by,
        approved_at,
        is_active
    ) VALUES (
        req.domain,
        req.proposed_version,
        req.proposed_data,
        req.change_summary,
        req.requested_by,
        auth.uid(),
        NOW(),
        true
    );
    
    -- Update registry
    UPDATE public.ssot_registry
    SET current_version = req.proposed_version,
        last_modified_at = NOW(),
        last_modified_by = auth.uid()
    WHERE domain = req.domain;
    
    -- Log deployment
    INSERT INTO public.ssot_deployment_log (
        domain,
        from_version,
        to_version,
        deployed_by,
        deployment_summary
    ) VALUES (
        req.domain,
        current_version,
        req.proposed_version,
        auth.uid(),
        jsonb_build_object(
            'request_id', req.id,
            'change_summary', req.change_summary,
            'approvers', jsonb_build_object(
                'tech_lead', req.tech_lead_approved_by,
                'qa_lead', req.qa_lead_approved_by,
                'product_owner', req.product_owner_approved_by,
                'ops_admin', req.ops_admin_approved_by
            )
        )
    );
    
    -- Mark request as deployed
    UPDATE public.ssot_change_requests
    SET status = 'deployed',
        deployed_at = NOW()
    WHERE id = p_request_id;
    
    RETURN jsonb_build_object(
        'success', true,
        'domain', req.domain,
        'version', req.proposed_version,
        'message', 'SSOT deployed successfully'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 6: RLS POLICIES
-- ============================================================================

ALTER TABLE public.ssot_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ssot_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ssot_change_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ssot_deployment_log ENABLE ROW LEVEL SECURITY;

-- All authenticated users can read SSOT
CREATE POLICY "All users read SSOT registry"
    ON public.ssot_registry FOR SELECT
    USING (true);

CREATE POLICY "All users read active SSOT versions"
    ON public.ssot_versions FOR SELECT
    USING (is_active = true);

-- Only super admins can modify SSOT registry
CREATE POLICY "Super admins manage SSOT registry"
    ON public.ssot_registry FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid() AND role = 'super_admin'
        )
    );

-- Content admins and above can request changes
CREATE POLICY "Admins request SSOT changes"
    ON public.ssot_change_requests FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid()
              AND role IN ('content_admin', 'ops_admin', 'super_admin')
        )
    );

-- All admins can view change requests
CREATE POLICY "Admins view SSOT change requests"
    ON public.ssot_change_requests FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid()
              AND role IN ('content_admin', 'ops_admin', 'super_admin', 'reviewer')
        )
    );

-- Only super admins can view deployment log
CREATE POLICY "Super admins view deployment log"
    ON public.ssot_deployment_log FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid() AND role = 'super_admin'
        )
    );

COMMENT ON TABLE public.ssot_registry IS 'Registry of all SSOT domains with version tracking.';
COMMENT ON TABLE public.ssot_versions IS 'Immutable version history of all SSOT changes.';
COMMENT ON TABLE public.ssot_change_requests IS 'Approval workflow for SSOT modifications.';
COMMENT ON TABLE public.ssot_deployment_log IS 'Audit log of all SSOT deployments.';
COMMENT ON FUNCTION public.get_ssot IS 'Get current active SSOT for a domain.';
