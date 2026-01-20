-- ============================================================================
-- EASYWIN 1.0 - QA GATES & TESTING FRAMEWORK
-- CI-enforced validation gates with golden snapshots and regression guards
-- ============================================================================

-- PART 1: QA GATE DEFINITIONS
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.qa_gates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    gate_name TEXT NOT NULL UNIQUE,
    gate_category TEXT NOT NULL CHECK (gate_category IN ('ssot', 'schema', 'content', 'business_rules', 'regression')),
    description TEXT NOT NULL,
    validation_query TEXT NOT NULL, -- SQL query that must return true
    is_required BOOLEAN DEFAULT true,
    is_active BOOLEAN DEFAULT true,
    failure_action TEXT NOT NULL CHECK (failure_action IN ('fail_build', 'warn', 'block_deploy')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    last_modified_at TIMESTAMPTZ DEFAULT NOW()
);

-- Insert QA gates
INSERT INTO public.qa_gates (gate_name, gate_category, description, validation_query, failure_action) VALUES
    -- SSOT Validation
    ('ssot_single_source', 'ssot', 'Exactly one active SSOT per domain',
     'SELECT COUNT(*) = (SELECT COUNT(DISTINCT domain) FROM public.ssot_versions WHERE is_active = true) FROM public.ssot_registry',
     'fail_build'),
    
    ('ssot_version_bump', 'ssot', 'SSOT changes require version bump',
     'SELECT NOT EXISTS (SELECT 1 FROM public.ssot_change_requests WHERE status = ''deployed'' AND proposed_version <= (SELECT current_version FROM public.ssot_registry WHERE domain = ssot_change_requests.domain))',
     'fail_build'),
    
    -- Schema & Data Integrity
    ('no_orphan_questions', 'schema', 'All questions belong to a quiz or exam',
     'SELECT NOT EXISTS (SELECT 1 FROM public.questions WHERE quiz_id IS NULL AND exam_id IS NULL)',
     'fail_build'),
    
    ('fk_enforcement', 'schema', 'All foreign keys are valid',
     'SELECT COUNT(*) = 0 FROM (SELECT conname FROM pg_constraint WHERE contype = ''f'' AND NOT convalidated) AS invalid_fks',
     'fail_build'),
    
    ('no_null_user_attempts', 'schema', 'User attempts must have valid user_id',
     'SELECT NOT EXISTS (SELECT 1 FROM public.user_attempts WHERE user_id IS NULL AND deleted_at IS NULL)',
     'fail_build'),
    
    -- Content Safety
    ('question_count_matches', 'content', 'Question count matches metadata',
     'SELECT COUNT(*) = (SELECT SUM((metadata->>''question_count'')::INTEGER) FROM public.assessments WHERE metadata IS NOT NULL) FROM public.questions',
     'warn'),
    
    ('valid_answers', 'content', 'All questions have valid correct answers',
     'SELECT NOT EXISTS (SELECT 1 FROM public.questions WHERE correct_option NOT IN (''A'', ''B'', ''C'', ''D''))',
     'fail_build'),
    
    ('explanations_present', 'content', 'All questions have explanations',
     'SELECT COUNT(*) = (SELECT COUNT(*) FROM public.questions) FROM public.questions WHERE explanation IS NOT NULL AND LENGTH(explanation) > 10',
     'warn'),
    
    -- Business Rules
    ('coin_logic_unchanged', 'business_rules', 'Coin economy SSOT unchanged or approved',
     'SELECT NOT EXISTS (SELECT 1 FROM public.ssot_change_requests WHERE domain = ''coin_economy'' AND status = ''pending'')',
     'block_deploy'),
    
    ('premium_rules_unchanged', 'business_rules', 'Premium access rules unchanged or approved',
     'SELECT NOT EXISTS (SELECT 1 FROM public.ssot_change_requests WHERE domain = ''premium_access'' AND status = ''pending'')',
     'block_deploy'),
    
    -- Regression Guards
    ('quiz_attempt_flow', 'regression', 'Quiz attempt flow intact',
     'SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = ''create_quiz_attempt'')',
     'fail_build'),
    
    ('coin_deduction_intact', 'regression', 'Coin deduction logic intact',
     'SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = ''deduct_coins'')',
     'fail_build'),
    
    ('offline_sync_intact', 'regression', 'Offline sync rules intact',
     'SELECT data IS NOT NULL FROM public.ssot_versions WHERE domain = ''offline_sync'' AND is_active = true',
     'fail_build')
ON CONFLICT (gate_name) DO NOTHING;

-- PART 2: GOLDEN SNAPSHOTS
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.golden_snapshots (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    snapshot_name TEXT NOT NULL,
    snapshot_type TEXT NOT NULL CHECK (snapshot_type IN ('quiz_json', 'scoring_output', 'coin_deltas', 'admin_rules')),
    snapshot_data JSONB NOT NULL,
    snapshot_hash TEXT NOT NULL, -- SHA-256 hash for change detection
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    approved_by UUID REFERENCES auth.users(id),
    approved_at TIMESTAMPTZ,
    is_current BOOLEAN DEFAULT true,
    
    CONSTRAINT unique_snapshot_version UNIQUE(snapshot_name, version)
);

CREATE INDEX idx_golden_snapshots_current ON public.golden_snapshots(snapshot_name) WHERE is_current = true;

-- PART 3: QA EXECUTION LOG
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.qa_execution_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    execution_id UUID NOT NULL, -- Groups all gates in one run
    gate_name TEXT NOT NULL REFERENCES public.qa_gates(gate_name),
    executed_at TIMESTAMPTZ DEFAULT NOW(),
    passed BOOLEAN NOT NULL,
    failure_reason TEXT,
    execution_time_ms INTEGER,
    triggered_by TEXT NOT NULL, -- 'ci', 'manual', 'pre_deploy'
    build_id TEXT, -- CI build identifier
    
    CONSTRAINT valid_execution_time CHECK (execution_time_ms >= 0)
);

CREATE INDEX idx_qa_execution_log_execution ON public.qa_execution_log(execution_id);
CREATE INDEX idx_qa_execution_log_gate ON public.qa_execution_log(gate_name, executed_at DESC);
CREATE INDEX idx_qa_execution_log_build ON public.qa_execution_log(build_id) WHERE build_id IS NOT NULL;

-- PART 4: SNAPSHOT CHANGE DETECTION
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.snapshot_changes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    snapshot_name TEXT NOT NULL,
    old_hash TEXT NOT NULL,
    new_hash TEXT NOT NULL,
    detected_at TIMESTAMPTZ DEFAULT NOW(),
    diff JSONB, -- JSON diff of changes
    approval_status TEXT NOT NULL DEFAULT 'pending' CHECK (approval_status IN ('pending', 'approved', 'rejected')),
    approved_by UUID REFERENCES auth.users(id),
    approved_at TIMESTAMPTZ,
    rejection_reason TEXT
);

CREATE INDEX idx_snapshot_changes_status ON public.snapshot_changes(approval_status);
CREATE INDEX idx_snapshot_changes_snapshot ON public.snapshot_changes(snapshot_name, detected_at DESC);

-- PART 5: QA GATE EXECUTION FUNCTIONS
-- ============================================================================

-- Function: Run all QA gates
CREATE OR REPLACE FUNCTION public.run_qa_gates(
    p_triggered_by TEXT DEFAULT 'manual',
    p_build_id TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    execution_id UUID;
    gate RECORD;
    gate_result BOOLEAN;
    total_gates INTEGER := 0;
    passed_gates INTEGER := 0;
    failed_gates INTEGER := 0;
    blocked_gates INTEGER := 0;
    start_time TIMESTAMPTZ;
    end_time TIMESTAMPTZ;
    execution_time INTEGER;
    results JSONB := '[]'::JSONB;
BEGIN
    execution_id := gen_random_uuid();
    
    FOR gate IN SELECT * FROM public.qa_gates WHERE is_active = true ORDER BY gate_category, gate_name LOOP
        total_gates := total_gates + 1;
        start_time := clock_timestamp();
        
        BEGIN
            -- Execute validation query
            EXECUTE 'SELECT (' || gate.validation_query || ')' INTO gate_result;
            
            end_time := clock_timestamp();
            execution_time := EXTRACT(MILLISECONDS FROM (end_time - start_time))::INTEGER;
            
            IF gate_result THEN
                passed_gates := passed_gates + 1;
                
                INSERT INTO public.qa_execution_log (
                    execution_id, gate_name, passed, execution_time_ms, triggered_by, build_id
                ) VALUES (
                    execution_id, gate.gate_name, true, execution_time, p_triggered_by, p_build_id
                );
                
                results := results || jsonb_build_object(
                    'gate', gate.gate_name,
                    'status', 'passed',
                    'execution_time_ms', execution_time
                );
            ELSE
                IF gate.failure_action = 'fail_build' THEN
                    failed_gates := failed_gates + 1;
                ELSIF gate.failure_action = 'block_deploy' THEN
                    blocked_gates := blocked_gates + 1;
                END IF;
                
                INSERT INTO public.qa_execution_log (
                    execution_id, gate_name, passed, failure_reason, execution_time_ms, triggered_by, build_id
                ) VALUES (
                    execution_id, gate.gate_name, false, 'Validation query returned false', execution_time, p_triggered_by, p_build_id
                );
                
                results := results || jsonb_build_object(
                    'gate', gate.gate_name,
                    'status', 'failed',
                    'action', gate.failure_action,
                    'execution_time_ms', execution_time
                );
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                failed_gates := failed_gates + 1;
                
                INSERT INTO public.qa_execution_log (
                    execution_id, gate_name, passed, failure_reason, triggered_by, build_id
                ) VALUES (
                    execution_id, gate.gate_name, false, SQLERRM, p_triggered_by, p_build_id
                );
                
                results := results || jsonb_build_object(
                    'gate', gate.gate_name,
                    'status', 'error',
                    'error', SQLERRM
                );
        END;
    END LOOP;
    
    RETURN jsonb_build_object(
        'execution_id', execution_id,
        'total_gates', total_gates,
        'passed', passed_gates,
        'failed', failed_gates,
        'blocked', blocked_gates,
        'build_should_fail', (failed_gates > 0),
        'deploy_should_block', (blocked_gates > 0),
        'results', results
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Create golden snapshot
CREATE OR REPLACE FUNCTION public.create_golden_snapshot(
    p_snapshot_name TEXT,
    p_snapshot_type TEXT,
    p_snapshot_data JSONB
)
RETURNS JSONB AS $$
DECLARE
    snapshot_hash TEXT;
    new_version INTEGER;
BEGIN
    -- Generate hash
    snapshot_hash := encode(digest(p_snapshot_data::TEXT, 'sha256'), 'hex');
    
    -- Get next version
    SELECT COALESCE(MAX(version), 0) + 1 INTO new_version
    FROM public.golden_snapshots
    WHERE snapshot_name = p_snapshot_name;
    
    -- Deactivate current snapshot
    UPDATE public.golden_snapshots
    SET is_current = false
    WHERE snapshot_name = p_snapshot_name
      AND is_current = true;
    
    -- Insert new snapshot
    INSERT INTO public.golden_snapshots (
        snapshot_name,
        snapshot_type,
        snapshot_data,
        snapshot_hash,
        version,
        approved_by
    ) VALUES (
        p_snapshot_name,
        p_snapshot_type,
        p_snapshot_data,
        snapshot_hash,
        new_version,
        auth.uid()
    );
    
    RETURN jsonb_build_object(
        'success', true,
        'snapshot_name', p_snapshot_name,
        'version', new_version,
        'hash', snapshot_hash
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Detect snapshot changes
CREATE OR REPLACE FUNCTION public.detect_snapshot_changes(
    p_snapshot_name TEXT,
    p_new_data JSONB
)
RETURNS JSONB AS $$
DECLARE
    current_snapshot RECORD;
    new_hash TEXT;
    change_id UUID;
BEGIN
    -- Get current snapshot
    SELECT * INTO current_snapshot
    FROM public.golden_snapshots
    WHERE snapshot_name = p_snapshot_name
      AND is_current = true;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'No current snapshot found');
    END IF;
    
    -- Generate new hash
    new_hash := encode(digest(p_new_data::TEXT, 'sha256'), 'hex');
    
    IF new_hash = current_snapshot.snapshot_hash THEN
        RETURN jsonb_build_object(
            'changed', false,
            'message', 'Snapshot unchanged'
        );
    ELSE
        -- Log change
        INSERT INTO public.snapshot_changes (
            snapshot_name,
            old_hash,
            new_hash,
            diff
        ) VALUES (
            p_snapshot_name,
            current_snapshot.snapshot_hash,
            new_hash,
            jsonb_build_object(
                'old', current_snapshot.snapshot_data,
                'new', p_new_data
            )
        ) RETURNING id INTO change_id;
        
        RETURN jsonb_build_object(
            'changed', true,
            'change_id', change_id,
            'message', 'Snapshot changed - human approval required',
            'old_hash', current_snapshot.snapshot_hash,
            'new_hash', new_hash
        );
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 6: RLS POLICIES
-- ============================================================================

ALTER TABLE public.qa_gates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.golden_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.qa_execution_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.snapshot_changes ENABLE ROW LEVEL SECURITY;

-- All authenticated users can read QA gates
CREATE POLICY "All users read QA gates"
    ON public.qa_gates FOR SELECT
    USING (true);

-- Only super admins can modify QA gates
CREATE POLICY "Super admins manage QA gates"
    ON public.qa_gates FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid() AND role = 'super_admin'
        )
    );

-- All admins can view golden snapshots
CREATE POLICY "Admins view golden snapshots"
    ON public.golden_snapshots FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid()
              AND role IN ('content_admin', 'ops_admin', 'super_admin')
        )
    );

-- All admins can view QA execution log
CREATE POLICY "Admins view QA execution log"
    ON public.qa_execution_log FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid()
              AND role IN ('content_admin', 'ops_admin', 'super_admin', 'reviewer')
        )
    );

-- All admins can view snapshot changes
CREATE POLICY "Admins view snapshot changes"
    ON public.snapshot_changes FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid()
              AND role IN ('content_admin', 'ops_admin', 'super_admin')
        )
    );

COMMENT ON TABLE public.qa_gates IS 'CI-enforced QA gates with build fail conditions.';
COMMENT ON TABLE public.golden_snapshots IS 'Golden snapshots for regression detection.';
COMMENT ON TABLE public.qa_execution_log IS 'Audit log of all QA gate executions.';
COMMENT ON TABLE public.snapshot_changes IS 'Detected changes requiring human approval.';
COMMENT ON FUNCTION public.run_qa_gates IS 'Execute all active QA gates and return results.';
