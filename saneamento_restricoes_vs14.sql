-- 1. Derruba qualquer conexão travada que restou no banco Aula9
SELECT pg_terminate_backend(pg_stat_activity.pid)
FROM pg_stat_activity
WHERE pg_stat_activity.datname = 'Aula9'
  AND pid <> pg_backend_pid();

-- 2. Remove o banco antigo com segurança
DROP DATABASE IF EXISTS "Aula9";

-- 3. Cria o banco limpo
CREATE DATABASE "Aula9";

-- 4. CONECTA NO NOVO BANCO (Comando essencial do psql)
\c "Aula9"

-- 5. Agora sim, cria os schemas e as extensões necessárias do seu projeto
CREATE SCHEMA IF NOT EXISTS topology;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology SCHEMA topology;

-- Funções
CREATE FUNCTION public.fn_calcular_extensao_trecho() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Converte a geometria para geografia e calcula o comprimento em metros
    NEW.extensao := ST_Length(NEW.geom::GEOGRAPHY);
    RETURN NEW;
END;
$$;

CREATE FUNCTION public.fn_inserir_fk_id_trecho_ocorrencia() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_trecho  INT;
    v_distancia  FLOAT;
BEGIN
    -- Busca o id_trecho e a distância do trecho mais próximo
    SELECT
        id_trecho,
        ST_Distance(NEW.geom::GEOGRAPHY, geom::GEOGRAPHY)
    INTO
        v_id_trecho,
        v_distancia
    FROM trecho
    ORDER BY ST_Distance(NEW.geom::GEOGRAPHY, geom::GEOGRAPHY)
    LIMIT 1;

    -- Bloqueia se nenhum trecho estiver cadastrado
    IF v_id_trecho IS NULL THEN
        RAISE EXCEPTION
            'Erro: Nenhum trecho de rede cadastrado no banco.
             Cadastre um trecho antes de registrar uma ocorrência.';
    END IF;

    -- Bloqueia se a ocorrência estiver além da tolerância de 1 metro
    IF v_distancia > 1.0 THEN
        RAISE EXCEPTION
            'Erro: A ocorrência está a %.4f metros do trecho mais próximo (id_trecho = %).
             A ocorrência deve estar sobre um trecho de rede cadastrado.',
            v_distancia, v_id_trecho;
    END IF;

    -- Insere o id_trecho automaticamente na coluna fk_id_trecho (FK)
    NEW.fk_id_trecho := v_id_trecho;

    -- Mensagem de confirmação no console
    RAISE NOTICE
        'Coluna pk_id_trecho preenchida automaticamente com id_trecho = % | Distância: %.6f metros.',
        v_id_trecho, v_distancia;

    RETURN NEW;
END;
$$;

CREATE FUNCTION public.fn_recuperar_id_bairro() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_bairro INT;
BEGIN
    -- Busca o bairro que contém a geometria do trecho
    SELECT id_bairro
    INTO v_id_bairro
    FROM bairro
    WHERE ST_Within(NEW.geom, geom)
    LIMIT 1;

    -- Se não encontrar nenhum bairro, lança erro
    IF v_id_bairro IS NULL THEN
        RAISE EXCEPTION
            'Erro: A geometria do trecho não está dentro de nenhum bairro cadastrado.
             Verifique as coordenadas informadas.';
    END IF;

    -- Grava o id_bairro automaticamente na FK
    NEW.fk_id_bairro := v_id_bairro;

    RAISE NOTICE
        'Bairro identificado automaticamente: id_bairro = %', v_id_bairro;

    RETURN NEW;
END;
$$;

CREATE FUNCTION public.fn_recuperar_id_trecho() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_trecho INT;
    v_distancia FLOAT;
BEGIN
    -- Busca o trecho mais próximo da ocorrência
    SELECT
        id_trecho,
        ST_Distance(NEW.geom::GEOGRAPHY, geom::GEOGRAPHY)
    INTO
        v_id_trecho,
        v_distancia
    FROM trecho
    ORDER BY ST_Distance(NEW.geom::GEOGRAPHY, geom::GEOGRAPHY)
    LIMIT 1;

    -- Se não encontrar nenhum trecho, bloqueia a inserção
    IF v_id_trecho IS NULL THEN
        RAISE EXCEPTION
            'Erro: Nenhum trecho de rede encontrado próximo à ocorrência.
             Verifique as coordenadas informadas.';
    END IF;

    -- Se o trecho mais próximo estiver a mais de 1 metro, bloqueia
    IF v_distancia > 1.0 THEN
        RAISE EXCEPTION
            'Erro: A ocorrência está a %.2f metros do trecho mais próximo.
             A ocorrência deve estar sobre um trecho de rede.',
            v_distancia;
    END IF;

    -- Grava o id_trecho automaticamente na FK
    NEW.id_trecho := fk_id_trecho;

    RAISE NOTICE
        'Trecho identificado automaticamente: id_trecho = % | Distância: %.4f metros',
        v_id_trecho, v_distancia;

    RETURN NEW;
END;
$$;

CREATE FUNCTION public.fn_validar_trecho_dentro_bairro() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_geom_bairro geometry;
BEGIN
    -- Busca a geometria do bairro informado
    SELECT geom
    INTO v_geom_bairro
    FROM bairro
    WHERE id_bairro = NEW.id_bairro;

    IF v_geom_bairro IS NULL THEN
        RAISE EXCEPTION 'Bairro informado não existe.';
    END IF;

    -- Verifica se o trecho está dentro do bairro
    IF NOT ST_Within(NEW.geom, v_geom_bairro) THEN
        RAISE EXCEPTION
            'O trecho de rede deve estar totalmente dentro do bairro informado.';
    END IF;

    RETURN NEW;
END;
$$;

-- Tabelas
CREATE TABLE public.bairro (
    id_bairro integer NOT NULL,
    nome character varying(100) NOT NULL,
    geom public.geometry(MultiPolygon,4326)
);

CREATE SEQUENCE public.bairro_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.bairro_id_seq OWNED BY public.bairro.id_bairro;

CREATE TABLE public.ocorrencia (
    id_ocorrencia integer NOT NULL,
    fk_id_trecho integer NOT NULL,
    data timestamp without time zone NOT NULL,
    tipo character varying(50),
    geom public.geometry(Point,4326)
);

CREATE SEQUENCE public.ocorrencia_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.ocorrencia_id_seq OWNED BY public.ocorrencia.id_ocorrencia;

CREATE TABLE public.trecho (
    id_trecho integer NOT NULL,
    fk_id_bairro integer NOT NULL,
    extensao numeric(10,2),
    geom public.geometry(LineString,4326)
);

CREATE SEQUENCE public.trecho_rede_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.trecho_rede_id_seq OWNED BY public.trecho.id_trecho;

-- Defaults
ALTER TABLE ONLY public.bairro ALTER COLUMN id_bairro SET DEFAULT nextval('public.bairro_id_seq'::regclass);
ALTER TABLE ONLY public.ocorrencia ALTER COLUMN id_ocorrencia SET DEFAULT nextval('public.ocorrencia_id_seq'::regclass);
ALTER TABLE ONLY public.trecho ALTER COLUMN id_trecho SET DEFAULT nextval('public.trecho_rede_id_seq'::regclass);

-- Chaves primárias
ALTER TABLE ONLY public.bairro
    ADD CONSTRAINT bairro_pkey PRIMARY KEY (id_bairro);

ALTER TABLE ONLY public.ocorrencia
    ADD CONSTRAINT ocorrencia_pkey PRIMARY KEY (id_ocorrencia);

ALTER TABLE ONLY public.trecho
    ADD CONSTRAINT trecho_rede_pkey PRIMARY KEY (id_trecho);

-- Índices
CREATE INDEX idx_bairro_geom ON public.bairro USING gist (geom);
CREATE INDEX idx_ocorrencia_local ON public.ocorrencia USING gist (geom);
CREATE INDEX idx_ocorrencia_trecho ON public.ocorrencia USING btree (fk_id_trecho);
CREATE INDEX idx_trecho_bairro ON public.trecho USING btree (fk_id_bairro);
CREATE INDEX idx_trecho_geom ON public.trecho USING gist (geom);

-- Chaves estrangeiras
ALTER TABLE ONLY public.ocorrencia
    ADD CONSTRAINT fk_ocorrencia_trecho FOREIGN KEY (fk_id_trecho) REFERENCES public.trecho(id_trecho) ON UPDATE CASCADE ON DELETE RESTRICT;

ALTER TABLE ONLY public.trecho
    ADD CONSTRAINT fk_trecho_bairro FOREIGN KEY (fk_id_bairro) REFERENCES public.bairro(id_bairro) ON UPDATE CASCADE ON DELETE RESTRICT;

-- Triggers
CREATE TRIGGER tg_calcular_extensao_trecho BEFORE INSERT OR UPDATE ON public.trecho FOR EACH ROW EXECUTE FUNCTION public.fn_calcular_extensao_trecho();
CREATE TRIGGER tg_inserir_fk_id_trecho_ocorrencia BEFORE INSERT OR UPDATE ON public.ocorrencia FOR EACH ROW EXECUTE FUNCTION public.fn_inserir_fk_id_trecho_ocorrencia();
CREATE TRIGGER tg_recuperar_id_bairro BEFORE INSERT OR UPDATE ON public.trecho FOR EACH ROW EXECUTE FUNCTION public.fn_recuperar_id_bairro();

-- Recriar sequências com os valores originais
SELECT pg_catalog.setval('public.bairro_id_seq', 7, true);
SELECT pg_catalog.setval('public.ocorrencia_id_seq', 52, true);
SELECT pg_catalog.setval('public.trecho_rede_id_seq', 28, true);