-- Player account and Twilio phone-recovery migration checks.
DO $$
DECLARE
  v_user uuid := '22222222-2222-4222-8222-222222222222';
  v_profile_guest boolean;
  v_rejected boolean := false;
BEGIN
  INSERT INTO auth.users (id, email, raw_user_meta_data, is_anonymous, email_confirmed_at)
  VALUES (
    v_user,
    'player-test@example.invalid',
    '{"display_name":"Jogador Teste"}'::jsonb,
    true,
    NULL
  )
  ON CONFLICT (id) DO NOTHING;

  IF NOT EXISTS (
    SELECT 1 FROM public.player_profiles
    WHERE id = v_user AND display_name = 'Jogador Teste' AND is_guest = true AND points = 500
  ) THEN
    RAISE EXCEPTION 'Auth trigger did not create the guest player profile with 500 points';
  END IF;

  UPDATE auth.users
  SET is_anonymous = false, email_confirmed_at = now(), confirmed_at = now()
  WHERE id = v_user;

  SELECT is_guest INTO v_profile_guest
  FROM public.player_profiles WHERE id = v_user;
  IF v_profile_guest IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Player profile did not become permanent after identity confirmation';
  END IF;

  INSERT INTO public.player_recovery_contacts (user_id, phone_e164)
  VALUES (v_user, '+258841234567');

  IF NOT EXISTS (
    SELECT 1 FROM public.player_recovery_contacts
    WHERE user_id = v_user AND phone_e164 = '+258841234567'
  ) THEN
    RAISE EXCEPTION 'Recovery phone was not stored';
  END IF;

  BEGIN
    INSERT INTO public.player_recovery_contacts (user_id, phone_e164)
    VALUES (v_user, '841234567');
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Invalid non-E.164 recovery phone was accepted';
  END IF;

  IF has_table_privilege('anon', 'public.player_recovery_contacts', 'SELECT')
     OR has_table_privilege('authenticated', 'public.player_recovery_contacts', 'SELECT') THEN
    RAISE EXCEPTION 'Recovery phone table is readable by public client roles';
  END IF;

  IF has_function_privilege(
       'anon',
       'public.consume_phone_recovery_rate_limit(text,text,integer,integer)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'authenticated',
       'public.consume_phone_recovery_rate_limit(text,text,integer,integer)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'service_role',
       'public.consume_phone_recovery_rate_limit(text,text,integer,integer)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Recovery rate-limit RPC permissions are incorrect';
  END IF;
END $$;

SET ROLE service_role;
DO $$
DECLARE
  v_key text := repeat('a', 64);
BEGIN
  IF public.consume_phone_recovery_rate_limit('phone', v_key, 3, 900) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'First recovery request should be allowed';
  END IF;
  IF public.consume_phone_recovery_rate_limit('phone', v_key, 3, 900) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Second recovery request should be allowed';
  END IF;
  IF public.consume_phone_recovery_rate_limit('phone', v_key, 3, 900) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Third recovery request should be allowed';
  END IF;
  IF public.consume_phone_recovery_rate_limit('phone', v_key, 3, 900) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Fourth recovery request should be rate limited';
  END IF;
END $$;
RESET ROLE;
