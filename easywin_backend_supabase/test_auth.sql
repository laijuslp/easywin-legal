-- Test RLS with simulated authenticated user
-- Run this to see what role your JWT tokens are using

-- Check table ownership and RLS status
SELECT 
    tablename, 
    tableowner,
    rowsecurity::text as rls_enabled
FROM pg_tables 
WHERE schemaname = 'public' 
AND tablename IN ('categories', 'assessments', 'questions');

-- Check grants on categories table
SELECT grantee, privilege_type 
FROM information_schema.role_table_grants 
WHERE table_name='categories' 
AND table_schema='public';

-- Check if authenticator role exists and has access
SELECT rolname, rolsuper, rolinherit, rolcreaterole, rolcreatedb 
FROM pg_roles 
WHERE rolname IN ('authenticator', 'authenticated', 'anon', 'postgres');

-- Test if authenticated role can select from categories
SET ROLE authenticated;
SELECT count(*) as category_count FROM categories;
RESET ROLE;
