-- Ephemeral PostgreSQL schema used only by GitHub Actions.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE IF NOT EXISTS auth.users (
  id uuid PRIMARY KEY,
  email text UNIQUE,
  raw_user_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_anonymous boolean DEFAULT true,
  email_confirmed_at timestamptz,
  confirmed_at timestamptz
);

CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

-- Existing RPCs are stubbed so migration privilege changes are tested in CI.
CREATE OR REPLACE FUNCTION auth.jwt()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $
  SELECT COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb)
$;

CREATE OR REPLACE FUNCTION public.create_game_room()
RETURNS TABLE(room_id uuid, room_code text)
LANGUAGE sql SECURITY DEFINER
AS 'SELECT gen_random_uuid(), ''ABC123''::text';

CREATE OR REPLACE FUNCTION public.join_game_room(p_code text)
RETURNS uuid
LANGUAGE sql SECURITY DEFINER
AS 'SELECT gen_random_uuid()';

CREATE OR REPLACE FUNCTION public.resign_game_room(p_room_id uuid)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
AS 'SELECT ''{}''::jsonb';

CREATE TABLE public.rooms (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,
  host_id uuid NOT NULL,
  guest_id uuid,
  board jsonb,
  current_turn text DEFAULT 'white',
  status text DEFAULT 'waiting',
  winner_id uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);
