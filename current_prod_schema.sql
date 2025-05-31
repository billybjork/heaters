--
-- PostgreSQL database dump
--

-- Dumped from database version 16.8 (Debian 16.8-1.pgdg120+1)
-- Dumped by pg_dump version 16.9 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: meatspace_app_db_user
--

-- *not* creating schema, since initdb creates it


ALTER SCHEMA public OWNER TO meatspace_app_db_user;

--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


--
-- Name: trigger_set_timestamp(); Type: FUNCTION; Schema: public; Owner: meatspace_app_db_user
--

CREATE FUNCTION public.trigger_set_timestamp() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.trigger_set_timestamp() OWNER TO meatspace_app_db_user;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: clip_artifacts; Type: TABLE; Schema: public; Owner: meatspace_app_db_user
--

CREATE TABLE public.clip_artifacts (
    id integer NOT NULL,
    clip_id integer NOT NULL,
    artifact_type text NOT NULL,
    strategy text,
    tag text,
    s3_key text NOT NULL,
    metadata jsonb,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.clip_artifacts OWNER TO meatspace_app_db_user;

--
-- Name: clip_artifacts_id_seq; Type: SEQUENCE; Schema: public; Owner: meatspace_app_db_user
--

CREATE SEQUENCE public.clip_artifacts_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.clip_artifacts_id_seq OWNER TO meatspace_app_db_user;

--
-- Name: clip_artifacts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: meatspace_app_db_user
--

ALTER SEQUENCE public.clip_artifacts_id_seq OWNED BY public.clip_artifacts.id;


--
-- Name: clip_events; Type: TABLE; Schema: public; Owner: meatspace_app_db_user
--

CREATE TABLE public.clip_events (
    id integer NOT NULL,
    clip_id integer NOT NULL,
    action text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    reviewer_id text,
    event_data jsonb,
    updated_at timestamp without time zone DEFAULT timezone('utc'::text, now()) NOT NULL
);


ALTER TABLE public.clip_events OWNER TO meatspace_app_db_user;

--
-- Name: TABLE clip_events; Type: COMMENT; Schema: public; Owner: meatspace_app_db_user
--

COMMENT ON TABLE public.clip_events IS 'Immutable log of events related to the clip review process.';


--
-- Name: COLUMN clip_events.clip_id; Type: COMMENT; Schema: public; Owner: meatspace_app_db_user
--

COMMENT ON COLUMN public.clip_events.clip_id IS 'References the clip the event pertains to.';


--
-- Name: COLUMN clip_events.action; Type: COMMENT; Schema: public; Owner: meatspace_app_db_user
--

COMMENT ON COLUMN public.clip_events.action IS 'The specific action taken or committed (e.g., selected_approve, undo, committed_skip).';


--
-- Name: COLUMN clip_events.created_at; Type: COMMENT; Schema: public; Owner: meatspace_app_db_user
--

COMMENT ON COLUMN public.clip_events.created_at IS 'Timestamp when the event was logged.';


--
-- Name: COLUMN clip_events.reviewer_id; Type: COMMENT; Schema: public; Owner: meatspace_app_db_user
--

COMMENT ON COLUMN public.clip_events.reviewer_id IS 'Identifier of the user performing the action (if tracked).';


--
-- Name: COLUMN clip_events.event_data; Type: COMMENT; Schema: public; Owner: meatspace_app_db_user
--

COMMENT ON COLUMN public.clip_events.event_data IS 'Optional JSON blob for additional event context.';


--
-- Name: clip_events_id_seq; Type: SEQUENCE; Schema: public; Owner: meatspace_app_db_user
--

CREATE SEQUENCE public.clip_events_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.clip_events_id_seq OWNER TO meatspace_app_db_user;

--
-- Name: clip_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: meatspace_app_db_user
--

ALTER SEQUENCE public.clip_events_id_seq OWNED BY public.clip_events.id;


--
-- Name: clips; Type: TABLE; Schema: public; Owner: meatspace_app_db_user
--

CREATE TABLE public.clips (
    id integer NOT NULL,
    source_video_id integer,
    clip_filepath text NOT NULL,
    clip_identifier text NOT NULL,
    start_frame integer,
    end_frame integer,
    start_time_seconds double precision,
    end_time_seconds double precision,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    ingest_state text DEFAULT 'new'::text NOT NULL,
    last_error text,
    retry_count integer DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    reviewed_at timestamp without time zone,
    keyframed_at timestamp without time zone,
    embedded_at timestamp without time zone,
    processing_metadata jsonb,
    grouped_with_clip_id integer,
    action_committed_at timestamp without time zone
);


ALTER TABLE public.clips OWNER TO meatspace_app_db_user;

--
-- Name: COLUMN clips.action_committed_at; Type: COMMENT; Schema: public; Owner: meatspace_app_db_user
--

COMMENT ON COLUMN public.clips.action_committed_at IS 'Timestamp when the final review action state was committed by the Commit Worker, making it eligible for pipeline pickup.';


--
-- Name: clips_id_seq; Type: SEQUENCE; Schema: public; Owner: meatspace_app_db_user
--

CREATE SEQUENCE public.clips_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.clips_id_seq OWNER TO meatspace_app_db_user;

--
-- Name: clips_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: meatspace_app_db_user
--

ALTER SEQUENCE public.clips_id_seq OWNED BY public.clips.id;


--
-- Name: embeddings; Type: TABLE; Schema: public; Owner: meatspace_app_db_user
--

CREATE TABLE public.embeddings (
    id integer NOT NULL,
    clip_id integer NOT NULL,
    embedding public.vector NOT NULL,
    model_name text NOT NULL,
    model_version text,
    generation_strategy text NOT NULL,
    generated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    embedding_dim integer
);


ALTER TABLE public.embeddings OWNER TO meatspace_app_db_user;

--
-- Name: embeddings_id_seq; Type: SEQUENCE; Schema: public; Owner: meatspace_app_db_user
--

CREATE SEQUENCE public.embeddings_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.embeddings_id_seq OWNER TO meatspace_app_db_user;

--
-- Name: embeddings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: meatspace_app_db_user
--

ALTER SEQUENCE public.embeddings_id_seq OWNED BY public.embeddings.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: meatspace_app_db_user
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


ALTER TABLE public.schema_migrations OWNER TO meatspace_app_db_user;

--
-- Name: source_videos; Type: TABLE; Schema: public; Owner: meatspace_app_db_user
--

CREATE TABLE public.source_videos (
    id integer NOT NULL,
    filepath text,
    duration_seconds double precision,
    fps double precision,
    width integer,
    height integer,
    published_date date,
    web_scraped boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    title text NOT NULL,
    ingest_state text DEFAULT 'new'::text NOT NULL,
    last_error text,
    retry_count integer DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    downloaded_at timestamp with time zone,
    spliced_at timestamp with time zone,
    original_url text
);


ALTER TABLE public.source_videos OWNER TO meatspace_app_db_user;

--
-- Name: source_videos_id_seq; Type: SEQUENCE; Schema: public; Owner: meatspace_app_db_user
--

CREATE SEQUENCE public.source_videos_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.source_videos_id_seq OWNER TO meatspace_app_db_user;

--
-- Name: source_videos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: meatspace_app_db_user
--

ALTER SEQUENCE public.source_videos_id_seq OWNED BY public.source_videos.id;


--
-- Name: clip_artifacts id; Type: DEFAULT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.clip_artifacts ALTER COLUMN id SET DEFAULT nextval('public.clip_artifacts_id_seq'::regclass);


--
-- Name: clip_events id; Type: DEFAULT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.clip_events ALTER COLUMN id SET DEFAULT nextval('public.clip_events_id_seq'::regclass);


--
-- Name: clips id; Type: DEFAULT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.clips ALTER COLUMN id SET DEFAULT nextval('public.clips_id_seq'::regclass);


--
-- Name: embeddings id; Type: DEFAULT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.embeddings ALTER COLUMN id SET DEFAULT nextval('public.embeddings_id_seq'::regclass);


--
-- Name: source_videos id; Type: DEFAULT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.source_videos ALTER COLUMN id SET DEFAULT nextval('public.source_videos_id_seq'::regclass);


--
-- Name: clip_artifacts clip_artifacts_pkey; Type: CONSTRAINT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.clip_artifacts
    ADD CONSTRAINT clip_artifacts_pkey PRIMARY KEY (id);


--
-- Name: clip_artifacts clip_artifacts_s3_key_key; Type: CONSTRAINT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.clip_artifacts
    ADD CONSTRAINT clip_artifacts_s3_key_key UNIQUE (s3_key);


--
-- Name: clip_events clip_events_pkey; Type: CONSTRAINT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.clip_events
    ADD CONSTRAINT clip_events_pkey PRIMARY KEY (id);


--
-- Name: clips clips_clip_filepath_key; Type: CONSTRAINT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.clips
    ADD CONSTRAINT clips_clip_filepath_key UNIQUE (clip_filepath);


--
-- Name: clips clips_clip_identifier_key; Type: CONSTRAINT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.clips
    ADD CONSTRAINT clips_clip_identifier_key UNIQUE (clip_identifier);


--
-- Name: clips clips_pkey; Type: CONSTRAINT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.clips
    ADD CONSTRAINT clips_pkey PRIMARY KEY (id);


--
-- Name: embeddings embeddings_clip_id_model_name_generation_strategy_key; Type: CONSTRAINT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.embeddings
    ADD CONSTRAINT embeddings_clip_id_model_name_generation_strategy_key UNIQUE (clip_id, model_name, generation_strategy);


--
-- Name: embeddings embeddings_pkey; Type: CONSTRAINT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.embeddings
    ADD CONSTRAINT embeddings_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: source_videos source_videos_filepath_key; Type: CONSTRAINT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.source_videos
    ADD CONSTRAINT source_videos_filepath_key UNIQUE (filepath);


--
-- Name: source_videos source_videos_pkey; Type: CONSTRAINT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.source_videos
    ADD CONSTRAINT source_videos_pkey PRIMARY KEY (id);


--
-- Name: clip_artifacts uq_clip_artifact_identity; Type: CONSTRAINT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.clip_artifacts
    ADD CONSTRAINT uq_clip_artifact_identity UNIQUE (clip_id, artifact_type, strategy, tag);


--
-- Name: clip_artifacts_clip_id_idx; Type: INDEX; Schema: public; Owner: meatspace_app_db_user
--

CREATE INDEX clip_artifacts_clip_id_idx ON public.clip_artifacts USING btree (clip_id);


--
-- Name: clips_action_committed_at_idx; Type: INDEX; Schema: public; Owner: meatspace_app_db_user
--

CREATE INDEX clips_action_committed_at_idx ON public.clips USING btree (action_committed_at) WHERE (action_committed_at IS NOT NULL);


--
-- Name: clips_review_queue_idx; Type: INDEX; Schema: public; Owner: meatspace_app_db_user
--

CREATE INDEX clips_review_queue_idx ON public.clips USING btree (ingest_state, reviewed_at, updated_at, id);


--
-- Name: idx_clip_artifacts_clip_id; Type: INDEX; Schema: public; Owner: meatspace_app_db_user
--

CREATE INDEX idx_clip_artifacts_clip_id ON public.clip_artifacts USING btree (clip_id);


--
-- Name: idx_clip_artifacts_clip_id_type; Type: INDEX; Schema: public; Owner: meatspace_app_db_user
--

CREATE INDEX idx_clip_artifacts_clip_id_type ON public.clip_artifacts USING btree (clip_id, artifact_type);


--
-- Name: idx_clip_artifacts_representative_tag; Type: INDEX; Schema: public; Owner: meatspace_app_db_user
--

CREATE INDEX idx_clip_artifacts_representative_tag ON public.clip_artifacts USING btree (clip_id, artifact_type, tag) WHERE (tag = 'representative'::text);


--
-- Name: idx_clip_artifacts_type_strategy; Type: INDEX; Schema: public; Owner: meatspace_app_db_user
--

CREATE INDEX idx_clip_artifacts_type_strategy ON public.clip_artifacts USING btree (clip_id, artifact_type, strategy);


--
-- Name: idx_clip_events_clip_id_created_at; Type: INDEX; Schema: public; Owner: meatspace_app_db_user
--

CREATE INDEX idx_clip_events_clip_id_created_at ON public.clip_events USING btree (clip_id, created_at DESC);


--
-- Name: idx_clips_cleanup; Type: INDEX; Schema: public; Owner: meatspace_app_db_user
--

CREATE INDEX idx_clips_cleanup ON public.clips USING btree (ingest_state, updated_at);


--
-- Name: idx_clips_grouped_with_clip_id; Type: INDEX; Schema: public; Owner: meatspace_app_db_user
--

CREATE INDEX idx_clips_grouped_with_clip_id ON public.clips USING btree (grouped_with_clip_id);


--
-- Name: idx_clips_id; Type: INDEX; Schema: public; Owner: meatspace_app_db_user
--

CREATE INDEX idx_clips_id ON public.clips USING btree (id);


--
-- Name: idx_clips_ingest_state; Type: INDEX; Schema: public; Owner: meatspace_app_db_user
--

CREATE INDEX idx_clips_ingest_state ON public.clips USING btree (ingest_state);


--
-- Name: idx_clips_ingest_state_updated_at_id; Type: INDEX; Schema: public; Owner: meatspace_app_db_user
--

CREATE INDEX idx_clips_ingest_state_updated_at_id ON public.clips USING btree (ingest_state, updated_at, id) WHERE (ingest_state = 'pending_review'::text);


--
-- Name: idx_clips_source_video_id; Type: INDEX; Schema: public; Owner: meatspace_app_db_user
--

CREATE INDEX idx_clips_source_video_id ON public.clips USING btree (source_video_id);


--
-- Name: idx_embeddings_lookup; Type: INDEX; Schema: public; Owner: meatspace_app_db_user
--

CREATE INDEX idx_embeddings_lookup ON public.embeddings USING btree (clip_id, model_name, generation_strategy);


--
-- Name: idx_source_videos_identifier; Type: INDEX; Schema: public; Owner: meatspace_app_db_user
--

CREATE INDEX idx_source_videos_identifier ON public.source_videos USING btree (title);


--
-- Name: idx_source_videos_ingest_state; Type: INDEX; Schema: public; Owner: meatspace_app_db_user
--

CREATE INDEX idx_source_videos_ingest_state ON public.source_videos USING btree (ingest_state);


--
-- Name: idx_source_videos_title; Type: INDEX; Schema: public; Owner: meatspace_app_db_user
--

CREATE INDEX idx_source_videos_title ON public.source_videos USING btree (title text_pattern_ops);


--
-- Name: clips set_timestamp; Type: TRIGGER; Schema: public; Owner: meatspace_app_db_user
--

CREATE TRIGGER set_timestamp BEFORE UPDATE ON public.clips FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: source_videos set_timestamp; Type: TRIGGER; Schema: public; Owner: meatspace_app_db_user
--

CREATE TRIGGER set_timestamp BEFORE UPDATE ON public.source_videos FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: clip_artifacts clip_artifacts_clip_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.clip_artifacts
    ADD CONSTRAINT clip_artifacts_clip_id_fkey FOREIGN KEY (clip_id) REFERENCES public.clips(id) ON DELETE CASCADE;


--
-- Name: clips clips_source_video_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.clips
    ADD CONSTRAINT clips_source_video_id_fkey FOREIGN KEY (source_video_id) REFERENCES public.source_videos(id) ON DELETE SET NULL;


--
-- Name: embeddings embeddings_clip_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.embeddings
    ADD CONSTRAINT embeddings_clip_id_fkey FOREIGN KEY (clip_id) REFERENCES public.clips(id) ON DELETE CASCADE;


--
-- Name: clip_events fk_clip; Type: FK CONSTRAINT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.clip_events
    ADD CONSTRAINT fk_clip FOREIGN KEY (clip_id) REFERENCES public.clips(id) ON DELETE RESTRICT;


--
-- Name: clips fk_clips_grouped_with_clip_id; Type: FK CONSTRAINT; Schema: public; Owner: meatspace_app_db_user
--

ALTER TABLE ONLY public.clips
    ADD CONSTRAINT fk_clips_grouped_with_clip_id FOREIGN KEY (grouped_with_clip_id) REFERENCES public.clips(id) ON DELETE SET NULL;


--
-- Name: FUNCTION halfvec_in(cstring, oid, integer); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_in(cstring, oid, integer) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_out(public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_out(public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_recv(internal, oid, integer); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_recv(internal, oid, integer) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_send(public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_send(public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_typmod_in(cstring[]); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_typmod_in(cstring[]) TO meatspace_app_db_user;


--
-- Name: TYPE halfvec; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TYPE public.halfvec TO meatspace_app_db_user;


--
-- Name: FUNCTION sparsevec_in(cstring, oid, integer); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sparsevec_in(cstring, oid, integer) TO meatspace_app_db_user;


--
-- Name: FUNCTION sparsevec_out(public.sparsevec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sparsevec_out(public.sparsevec) TO meatspace_app_db_user;


--
-- Name: FUNCTION sparsevec_recv(internal, oid, integer); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sparsevec_recv(internal, oid, integer) TO meatspace_app_db_user;


--
-- Name: FUNCTION sparsevec_send(public.sparsevec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sparsevec_send(public.sparsevec) TO meatspace_app_db_user;


--
-- Name: FUNCTION sparsevec_typmod_in(cstring[]); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sparsevec_typmod_in(cstring[]) TO meatspace_app_db_user;


--
-- Name: TYPE sparsevec; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TYPE public.sparsevec TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_in(cstring, oid, integer); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_in(cstring, oid, integer) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_out(public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_out(public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_recv(internal, oid, integer); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_recv(internal, oid, integer) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_send(public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_send(public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_typmod_in(cstring[]); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_typmod_in(cstring[]) TO meatspace_app_db_user;


--
-- Name: TYPE vector; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TYPE public.vector TO meatspace_app_db_user;


--
-- Name: FUNCTION array_to_halfvec(real[], integer, boolean); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.array_to_halfvec(real[], integer, boolean) TO meatspace_app_db_user;


--
-- Name: FUNCTION array_to_vector(real[], integer, boolean); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.array_to_vector(real[], integer, boolean) TO meatspace_app_db_user;


--
-- Name: FUNCTION array_to_halfvec(double precision[], integer, boolean); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.array_to_halfvec(double precision[], integer, boolean) TO meatspace_app_db_user;


--
-- Name: FUNCTION array_to_vector(double precision[], integer, boolean); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.array_to_vector(double precision[], integer, boolean) TO meatspace_app_db_user;


--
-- Name: FUNCTION array_to_halfvec(integer[], integer, boolean); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.array_to_halfvec(integer[], integer, boolean) TO meatspace_app_db_user;


--
-- Name: FUNCTION array_to_vector(integer[], integer, boolean); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.array_to_vector(integer[], integer, boolean) TO meatspace_app_db_user;


--
-- Name: FUNCTION array_to_halfvec(numeric[], integer, boolean); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.array_to_halfvec(numeric[], integer, boolean) TO meatspace_app_db_user;


--
-- Name: FUNCTION array_to_vector(numeric[], integer, boolean); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.array_to_vector(numeric[], integer, boolean) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_to_float4(public.halfvec, integer, boolean); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_to_float4(public.halfvec, integer, boolean) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec(public.halfvec, integer, boolean); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec(public.halfvec, integer, boolean) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_to_sparsevec(public.halfvec, integer, boolean); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_to_sparsevec(public.halfvec, integer, boolean) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_to_vector(public.halfvec, integer, boolean); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_to_vector(public.halfvec, integer, boolean) TO meatspace_app_db_user;


--
-- Name: FUNCTION sparsevec_to_halfvec(public.sparsevec, integer, boolean); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sparsevec_to_halfvec(public.sparsevec, integer, boolean) TO meatspace_app_db_user;


--
-- Name: FUNCTION sparsevec(public.sparsevec, integer, boolean); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sparsevec(public.sparsevec, integer, boolean) TO meatspace_app_db_user;


--
-- Name: FUNCTION sparsevec_to_vector(public.sparsevec, integer, boolean); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sparsevec_to_vector(public.sparsevec, integer, boolean) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_to_float4(public.vector, integer, boolean); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_to_float4(public.vector, integer, boolean) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_to_halfvec(public.vector, integer, boolean); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_to_halfvec(public.vector, integer, boolean) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_to_sparsevec(public.vector, integer, boolean); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_to_sparsevec(public.vector, integer, boolean) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector(public.vector, integer, boolean); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector(public.vector, integer, boolean) TO meatspace_app_db_user;


--
-- Name: FUNCTION binary_quantize(public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.binary_quantize(public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION binary_quantize(public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.binary_quantize(public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION cosine_distance(public.halfvec, public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.cosine_distance(public.halfvec, public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION cosine_distance(public.sparsevec, public.sparsevec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.cosine_distance(public.sparsevec, public.sparsevec) TO meatspace_app_db_user;


--
-- Name: FUNCTION cosine_distance(public.vector, public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.cosine_distance(public.vector, public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_accum(double precision[], public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_accum(double precision[], public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_add(public.halfvec, public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_add(public.halfvec, public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_avg(double precision[]); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_avg(double precision[]) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_cmp(public.halfvec, public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_cmp(public.halfvec, public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_combine(double precision[], double precision[]); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_combine(double precision[], double precision[]) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_concat(public.halfvec, public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_concat(public.halfvec, public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_eq(public.halfvec, public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_eq(public.halfvec, public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_ge(public.halfvec, public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_ge(public.halfvec, public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_gt(public.halfvec, public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_gt(public.halfvec, public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_l2_squared_distance(public.halfvec, public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_l2_squared_distance(public.halfvec, public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_le(public.halfvec, public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_le(public.halfvec, public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_lt(public.halfvec, public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_lt(public.halfvec, public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_mul(public.halfvec, public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_mul(public.halfvec, public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_ne(public.halfvec, public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_ne(public.halfvec, public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_negative_inner_product(public.halfvec, public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_negative_inner_product(public.halfvec, public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_spherical_distance(public.halfvec, public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_spherical_distance(public.halfvec, public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION halfvec_sub(public.halfvec, public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.halfvec_sub(public.halfvec, public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION hamming_distance(bit, bit); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.hamming_distance(bit, bit) TO meatspace_app_db_user;


--
-- Name: FUNCTION hnsw_bit_support(internal); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.hnsw_bit_support(internal) TO meatspace_app_db_user;


--
-- Name: FUNCTION hnsw_halfvec_support(internal); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.hnsw_halfvec_support(internal) TO meatspace_app_db_user;


--
-- Name: FUNCTION hnsw_sparsevec_support(internal); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.hnsw_sparsevec_support(internal) TO meatspace_app_db_user;


--
-- Name: FUNCTION hnswhandler(internal); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.hnswhandler(internal) TO meatspace_app_db_user;


--
-- Name: FUNCTION inner_product(public.halfvec, public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.inner_product(public.halfvec, public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION inner_product(public.sparsevec, public.sparsevec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.inner_product(public.sparsevec, public.sparsevec) TO meatspace_app_db_user;


--
-- Name: FUNCTION inner_product(public.vector, public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.inner_product(public.vector, public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION ivfflat_bit_support(internal); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.ivfflat_bit_support(internal) TO meatspace_app_db_user;


--
-- Name: FUNCTION ivfflat_halfvec_support(internal); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.ivfflat_halfvec_support(internal) TO meatspace_app_db_user;


--
-- Name: FUNCTION ivfflathandler(internal); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.ivfflathandler(internal) TO meatspace_app_db_user;


--
-- Name: FUNCTION jaccard_distance(bit, bit); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.jaccard_distance(bit, bit) TO meatspace_app_db_user;


--
-- Name: FUNCTION l1_distance(public.halfvec, public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.l1_distance(public.halfvec, public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION l1_distance(public.sparsevec, public.sparsevec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.l1_distance(public.sparsevec, public.sparsevec) TO meatspace_app_db_user;


--
-- Name: FUNCTION l1_distance(public.vector, public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.l1_distance(public.vector, public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION l2_distance(public.halfvec, public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.l2_distance(public.halfvec, public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION l2_distance(public.sparsevec, public.sparsevec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.l2_distance(public.sparsevec, public.sparsevec) TO meatspace_app_db_user;


--
-- Name: FUNCTION l2_distance(public.vector, public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.l2_distance(public.vector, public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION l2_norm(public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.l2_norm(public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION l2_norm(public.sparsevec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.l2_norm(public.sparsevec) TO meatspace_app_db_user;


--
-- Name: FUNCTION l2_normalize(public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.l2_normalize(public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION l2_normalize(public.sparsevec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.l2_normalize(public.sparsevec) TO meatspace_app_db_user;


--
-- Name: FUNCTION l2_normalize(public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.l2_normalize(public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION sparsevec_cmp(public.sparsevec, public.sparsevec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sparsevec_cmp(public.sparsevec, public.sparsevec) TO meatspace_app_db_user;


--
-- Name: FUNCTION sparsevec_eq(public.sparsevec, public.sparsevec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sparsevec_eq(public.sparsevec, public.sparsevec) TO meatspace_app_db_user;


--
-- Name: FUNCTION sparsevec_ge(public.sparsevec, public.sparsevec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sparsevec_ge(public.sparsevec, public.sparsevec) TO meatspace_app_db_user;


--
-- Name: FUNCTION sparsevec_gt(public.sparsevec, public.sparsevec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sparsevec_gt(public.sparsevec, public.sparsevec) TO meatspace_app_db_user;


--
-- Name: FUNCTION sparsevec_l2_squared_distance(public.sparsevec, public.sparsevec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sparsevec_l2_squared_distance(public.sparsevec, public.sparsevec) TO meatspace_app_db_user;


--
-- Name: FUNCTION sparsevec_le(public.sparsevec, public.sparsevec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sparsevec_le(public.sparsevec, public.sparsevec) TO meatspace_app_db_user;


--
-- Name: FUNCTION sparsevec_lt(public.sparsevec, public.sparsevec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sparsevec_lt(public.sparsevec, public.sparsevec) TO meatspace_app_db_user;


--
-- Name: FUNCTION sparsevec_ne(public.sparsevec, public.sparsevec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sparsevec_ne(public.sparsevec, public.sparsevec) TO meatspace_app_db_user;


--
-- Name: FUNCTION sparsevec_negative_inner_product(public.sparsevec, public.sparsevec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sparsevec_negative_inner_product(public.sparsevec, public.sparsevec) TO meatspace_app_db_user;


--
-- Name: FUNCTION subvector(public.halfvec, integer, integer); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.subvector(public.halfvec, integer, integer) TO meatspace_app_db_user;


--
-- Name: FUNCTION subvector(public.vector, integer, integer); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.subvector(public.vector, integer, integer) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_accum(double precision[], public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_accum(double precision[], public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_add(public.vector, public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_add(public.vector, public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_avg(double precision[]); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_avg(double precision[]) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_cmp(public.vector, public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_cmp(public.vector, public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_combine(double precision[], double precision[]); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_combine(double precision[], double precision[]) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_concat(public.vector, public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_concat(public.vector, public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_dims(public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_dims(public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_dims(public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_dims(public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_eq(public.vector, public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_eq(public.vector, public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_ge(public.vector, public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_ge(public.vector, public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_gt(public.vector, public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_gt(public.vector, public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_l2_squared_distance(public.vector, public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_l2_squared_distance(public.vector, public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_le(public.vector, public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_le(public.vector, public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_lt(public.vector, public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_lt(public.vector, public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_mul(public.vector, public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_mul(public.vector, public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_ne(public.vector, public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_ne(public.vector, public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_negative_inner_product(public.vector, public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_negative_inner_product(public.vector, public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_norm(public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_norm(public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_spherical_distance(public.vector, public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_spherical_distance(public.vector, public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION vector_sub(public.vector, public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.vector_sub(public.vector, public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION avg(public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.avg(public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION avg(public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.avg(public.vector) TO meatspace_app_db_user;


--
-- Name: FUNCTION sum(public.halfvec); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sum(public.halfvec) TO meatspace_app_db_user;


--
-- Name: FUNCTION sum(public.vector); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sum(public.vector) TO meatspace_app_db_user;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: -; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres GRANT ALL ON SEQUENCES TO meatspace_app_db_user;


--
-- Name: DEFAULT PRIVILEGES FOR TYPES; Type: DEFAULT ACL; Schema: -; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres GRANT ALL ON TYPES TO meatspace_app_db_user;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: -; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres GRANT ALL ON FUNCTIONS TO meatspace_app_db_user;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: -; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres GRANT ALL ON TABLES TO meatspace_app_db_user;


--
-- PostgreSQL database dump complete
--

