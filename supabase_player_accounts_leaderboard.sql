-- Damas Moçambicanas TTJ
-- Player profiles, anonymous-to-permanent identity support, match history and leaderboard.
-- Historical rooms are intentionally not backfilled; only matches finished after this migration count.

CREATE SCHEMA IF NOT EXISTS app_private;
REVOKE ALL ON SCHEMA app_private FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.player_profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name text NOT NULL CHECK (char_length(btrim(display_name)) BETWEEN 2 AND 24),
  is_guest boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.player_profiles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.player_profiles FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.player_profiles TO authenticated;
GRANT UPDATE (display_name) ON TABLE public.player_profiles TO authenticated;

DROP POLICY IF EXISTS player_profiles_select_own ON public.player_profiles;
CREATE POLICY player_profiles_select_own
ON public.player_profiles FOR SELECT
TO authenticated
USING (id = (SELECT auth.uid()));

DROP POLICY IF EXISTS player_profiles_update_own ON public.player_profiles;
CREATE POLICY player_profiles_update_own
ON public.player_profiles FOR UPDATE
TO authenticated
USING (
  id = (SELECT auth.uid())
  AND COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), true) = false
)
WITH CHECK (
  id = (SELECT auth.uid())
  AND COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), true) = false
  AND char_length(btrim(display_name)) BETWEEN 2 AND 24
);

CREATE OR REPLACE FUNCTION app_private.sync_auth_user_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_name text;
BEGIN
  v_name := NULLIF(btrim(NEW.raw_user_meta_data->>'display_name'), '');
  IF v_name IS NULL THEN
    SELECT p.display_name INTO v_name
    FROM public.player_profiles AS p
    WHERE p.id = NEW.id;
  END IF;
  IF v_name IS NULL THEN
    v_name := 'Jogador-' || upper(substr(replace(NEW.id::text, '-', ''), 1, 6));
  END IF;

  INSERT INTO public.player_profiles (id, display_name, is_guest)
  VALUES (NEW.id, left(v_name, 24), COALESCE(NEW.is_anonymous, true))
  ON CONFLICT (id) DO UPDATE
  SET is_guest = EXCLUDED.is_guest,
      display_name = CASE
        WHEN NULLIF(btrim(NEW.raw_user_meta_data->>'display_name'), '') IS NOT NULL
          THEN EXCLUDED.display_name
        ELSE public.player_profiles.display_name
      END,
      updated_at = now();

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS on_auth_user_profile_sync ON auth.users;
CREATE TRIGGER on_auth_user_profile_sync
AFTER INSERT OR UPDATE OF is_anonymous, raw_user_meta_data
ON auth.users
FOR EACH ROW
EXECUTE FUNCTION app_private.sync_auth_user_profile();

-- Ensure users created before this feature also receive a profile.
INSERT INTO public.player_profiles (id, display_name, is_guest)
SELECT
  u.id,
  COALESCE(
    NULLIF(left(btrim(u.raw_user_meta_data->>'display_name'), 24), ''),
    'Jogador-' || upper(substr(replace(u.id::text, '-', ''), 1, 6))
  ),
  COALESCE(u.is_anonymous, true)
FROM auth.users AS u
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.player_match_results (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL UNIQUE REFERENCES public.rooms(id) ON DELETE RESTRICT,
  host_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  guest_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  winner_id uuid,
  result_type text NOT NULL CHECK (result_type IN ('win', 'draw')),
  end_reason text NOT NULL CHECK (end_reason IN ('win', 'resignation', 'draw')),
  finished_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT player_match_results_distinct_players CHECK (host_id <> guest_id),
  CONSTRAINT player_match_results_winner_valid CHECK (
    (result_type = 'draw' AND winner_id IS NULL)
    OR (result_type = 'win' AND winner_id IN (host_id, guest_id))
  )
);

ALTER TABLE public.player_match_results ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.player_match_results FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION app_private.record_finished_room_result()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_game_result jsonb;
  v_kind text;
  v_result_type text;
BEGIN
  IF OLD.status = 'finished' OR NEW.status <> 'finished' OR NEW.guest_id IS NULL THEN
    RETURN NEW;
  END IF;

  v_game_result := NEW.board->'gameResult';
  v_kind := v_game_result->>'type';

  IF v_kind IN ('win', 'resignation') AND NEW.winner_id IN (NEW.host_id, NEW.guest_id) THEN
    v_result_type := 'win';
  ELSIF v_kind = 'draw' AND NEW.winner_id IS NULL THEN
    v_result_type := 'draw';
  ELSE
    RETURN NEW;
  END IF;

  INSERT INTO public.player_match_results (
    room_id, host_id, guest_id, winner_id, result_type, end_reason
  )
  VALUES (
    NEW.id, NEW.host_id, NEW.guest_id, NEW.winner_id, v_result_type, v_kind
  )
  ON CONFLICT (room_id) DO NOTHING;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS on_room_finished_record_result ON public.rooms;
CREATE TRIGGER on_room_finished_record_result
AFTER UPDATE OF status ON public.rooms
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM 'finished' AND NEW.status = 'finished')
EXECUTE FUNCTION app_private.record_finished_room_result();

CREATE OR REPLACE FUNCTION public.get_player_leaderboard(p_limit integer DEFAULT 20)
RETURNS TABLE (
  player_id uuid,
  display_name text,
  wins bigint,
  losses bigint,
  draws bigint,
  matches bigint,
  points bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  WITH eligible_matches AS (
    SELECT r.*
    FROM public.player_match_results AS r
    JOIN public.player_profiles AS host_profile ON host_profile.id = r.host_id
    JOIN public.player_profiles AS guest_profile ON guest_profile.id = r.guest_id
    WHERE host_profile.is_guest = false
      AND guest_profile.is_guest = false
  ),
  outcomes AS (
    SELECT winner_id AS player_id, 1::bigint AS wins, 0::bigint AS losses, 0::bigint AS draws
    FROM eligible_matches
    WHERE result_type = 'win'
    UNION ALL
    SELECT CASE WHEN winner_id = host_id THEN guest_id ELSE host_id END,
           0::bigint, 1::bigint, 0::bigint
    FROM eligible_matches
    WHERE result_type = 'win'
    UNION ALL
    SELECT host_id, 0::bigint, 0::bigint, 1::bigint
    FROM eligible_matches
    WHERE result_type = 'draw'
    UNION ALL
    SELECT guest_id, 0::bigint, 0::bigint, 1::bigint
    FROM eligible_matches
    WHERE result_type = 'draw'
  ),
  totals AS (
    SELECT
      o.player_id,
      sum(o.wins)::bigint AS wins,
      sum(o.losses)::bigint AS losses,
      sum(o.draws)::bigint AS draws
    FROM outcomes AS o
    GROUP BY o.player_id
  )
  SELECT
    p.id,
    p.display_name,
    COALESCE(t.wins, 0)::bigint,
    COALESCE(t.losses, 0)::bigint,
    COALESCE(t.draws, 0)::bigint,
    (COALESCE(t.wins, 0) + COALESCE(t.losses, 0) + COALESCE(t.draws, 0))::bigint,
    (COALESCE(t.wins, 0) * 3 + COALESCE(t.draws, 0))::bigint
  FROM public.player_profiles AS p
  LEFT JOIN totals AS t ON t.player_id = p.id
  WHERE p.is_guest = false
  ORDER BY
    (COALESCE(t.wins, 0) * 3 + COALESCE(t.draws, 0)) DESC,
    COALESCE(t.wins, 0) DESC,
    (COALESCE(t.wins, 0) + COALESCE(t.losses, 0) + COALESCE(t.draws, 0)) DESC,
    p.display_name ASC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 20), 100));
$function$;

REVOKE ALL ON FUNCTION public.get_player_leaderboard(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_player_leaderboard(integer) TO anon, authenticated;

REVOKE ALL ON FUNCTION app_private.sync_auth_user_profile() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION app_private.record_finished_room_result() FROM PUBLIC, anon, authenticated;
