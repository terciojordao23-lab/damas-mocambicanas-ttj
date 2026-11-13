-- Damas Moçambicanas TTJ — private recovery contacts and abuse controls.
-- Apply after supabase_player_accounts_leaderboard.sql.

CREATE SCHEMA IF NOT EXISTS app_private;
REVOKE ALL ON SCHEMA app_private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA app_private TO service_role;

CREATE TABLE IF NOT EXISTS public.player_recovery_contacts (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  phone_e164 text NOT NULL UNIQUE
    CHECK (phone_e164 ~ '^\\+[1-9][0-9]{7,14}$'),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.player_recovery_contacts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.player_recovery_contacts FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE public.player_recovery_contacts TO service_role;

CREATE TABLE IF NOT EXISTS app_private.phone_recovery_rate_limits (
  key_type text NOT NULL CHECK (key_type IN ('phone', 'ip')),
  key_hash text NOT NULL,
  window_started_at timestamptz NOT NULL,
  attempts integer NOT NULL CHECK (attempts >= 1),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (key_type, key_hash)
);

ALTER TABLE app_private.phone_recovery_rate_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE app_private.phone_recovery_rate_limits FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE app_private.phone_recovery_rate_limits TO service_role;

CREATE INDEX IF NOT EXISTS phone_recovery_rate_limits_updated_idx
  ON app_private.phone_recovery_rate_limits (updated_at);

CREATE OR REPLACE FUNCTION public.consume_phone_recovery_rate_limit(
  p_key_type text,
  p_key_hash text,
  p_max_attempts integer,
  p_window_seconds integer
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $function$
DECLARE
  v_attempts integer;
  v_now timestamptz := pg_catalog.now();
BEGIN
  IF p_key_type NOT IN ('phone', 'ip')
     OR p_key_hash IS NULL
     OR p_key_hash = ''
     OR p_max_attempts < 1
     OR p_window_seconds < 1 THEN
    RAISE EXCEPTION 'Invalid phone recovery rate-limit arguments';
  END IF;

  DELETE FROM app_private.phone_recovery_rate_limits
  WHERE updated_at < v_now - interval '2 days';

  INSERT INTO app_private.phone_recovery_rate_limits (
    key_type, key_hash, window_started_at, attempts, updated_at
  )
  VALUES (p_key_type, p_key_hash, v_now, 1, v_now)
  ON CONFLICT (key_type, key_hash) DO UPDATE
  SET
    attempts = CASE
      WHEN app_private.phone_recovery_rate_limits.window_started_at
           <= v_now - pg_catalog.make_interval(secs => p_window_seconds)
        THEN 1
      ELSE app_private.phone_recovery_rate_limits.attempts + 1
    END,
    window_started_at = CASE
      WHEN app_private.phone_recovery_rate_limits.window_started_at
           <= v_now - pg_catalog.make_interval(secs => p_window_seconds)
        THEN v_now
      ELSE app_private.phone_recovery_rate_limits.window_started_at
    END,
    updated_at = v_now
  RETURNING attempts INTO v_attempts;

  RETURN v_attempts <= p_max_attempts;
END;
$function$;

REVOKE ALL ON FUNCTION public.consume_phone_recovery_rate_limit(text, text, integer, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consume_phone_recovery_rate_limit(text, text, integer, integer)
  TO service_role;
