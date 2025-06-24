-- Add free field to torrents table
ALTER TABLE torrents
ADD COLUMN free TEXT;

-- Also update the torrents_and_reports view to include the new free field
DROP VIEW torrents_and_reports;

CREATE VIEW torrents_and_reports AS
SELECT
    t.id,
    t.upload_factor,
    t.download_factor,
    t.seeders,
    t.leechers,
    t.completed,
    t.edition_group_id,
    t.created_at,
    t.updated_at,
    -- Always keep the actual created_by_id for internal queries
    t.created_by_id,
    -- Add display fields that respect anonymity
    CASE
        WHEN t.uploaded_as_anonymous THEN NULL
        ELSE t.created_by_id
    END as display_created_by_id,
    CASE
        WHEN t.uploaded_as_anonymous THEN NULL
        ELSE json_build_object('id', u.id, 'username', u.username)
    END AS display_created_by,
    t.info_hash,
    t.languages,
    t.release_name,
    t.release_group,
    t.description,
    t.file_amount_per_type,
    t.uploaded_as_anonymous,
    t.file_list,
    t.mediainfo,
    t.trumpable,
    t.staff_checked,
    t.container,
    t.size,
    t.duration,
    t.audio_codec,
    t.audio_bitrate,
    t.audio_bitrate_sampling,
    t.audio_channels,
    t.video_codec,
    t.features,
    t.subtitle_languages,
    t.video_resolution,
    t.free, -- Added the new free field here
    CASE
        WHEN EXISTS (SELECT 1 FROM torrent_reports WHERE reported_torrent_id = t.id) THEN json_agg(row_to_json(tr))
        ELSE '[]'::json
    END AS reports,
    CASE
        WHEN p.status = 'seeding' THEN 'seeding'
        WHEN p.status = 'leeching' THEN 'leeching'
        WHEN ta.snatched_at IS NOT NULL AND p.status IS NULL THEN 'snatched'
        ELSE NULL
    END AS peer_status
FROM
    torrents t
LEFT JOIN
    users u ON t.created_by_id = u.id
LEFT JOIN
    torrent_reports tr ON t.id = tr.reported_torrent_id
LEFT JOIN
    peers p ON t.id = p.torrent_id
LEFT JOIN
    torrent_activities ta ON t.id = ta.torrent_id AND p.status IS NULL
GROUP BY
    t.id, u.id, u.username, p.status, ta.snatched_at
ORDER BY
    t.id;

-- Also update the get_title_groups_and_edition_group_and_torrents_lite function to include the new free field

DROP FUNCTION get_title_groups_and_edition_group_and_torrents_lite;

CREATE FUNCTION get_title_groups_and_edition_group_and_torrents_lite(
    p_title_group_name TEXT DEFAULT '',
    p_torrent_staff_checked BOOLEAN DEFAULT NULL,
    p_torrent_reported BOOLEAN DEFAULT NULL,
    p_include_empty_groups BOOLEAN DEFAULT TRUE,
    p_sort_by TEXT DEFAULT 'title_group_original_release_date',
    p_order TEXT DEFAULT 'desc',
    p_limit BIGINT DEFAULT NULL,
    p_offset BIGINT DEFAULT NULL,
    p_torrent_created_by_id BIGINT DEFAULT NULL,
    p_torrent_snatched_by_id BIGINT DEFAULT NULL,
    p_requesting_user_id BIGINT DEFAULT NULL
)
RETURNS TABLE (
    title_group_id BIGINT,
    title_group_data JSONB
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    WITH snatched_torrents AS (
        SELECT torrent_id, snatched_at
        FROM torrent_activities
        WHERE p_torrent_snatched_by_id IS NOT NULL AND user_id = p_torrent_snatched_by_id
    ),
    filtered_torrents AS (
        SELECT t.*, st.snatched_at
        FROM torrents_and_reports t
        LEFT JOIN snatched_torrents st ON t.id = st.torrent_id
        WHERE (p_torrent_staff_checked IS NULL OR t.staff_checked = p_torrent_staff_checked)
        AND (
            p_torrent_reported IS NULL
            OR (p_torrent_reported = TRUE AND t.reports::jsonb <> '[]'::jsonb)
            OR (p_torrent_reported = FALSE AND t.reports::jsonb = '[]'::jsonb)
        )
        AND (p_torrent_created_by_id IS NULL OR
             (t.created_by_id = p_torrent_created_by_id AND
              (NOT t.uploaded_as_anonymous OR t.created_by_id = p_requesting_user_id)))
        AND (p_torrent_snatched_by_id IS NULL OR st.torrent_id IS NOT NULL)
    ),
    edition_groups_with_torrents AS (
        SELECT
            eg.id AS eg_id,
            eg.title_group_id,
            jsonb_strip_nulls(jsonb_build_object(
                'id', eg.id,
                'title_group_id', eg.title_group_id,
                'name', eg.name,
                'release_date', eg.release_date,
                'distributor', eg.distributor,
                'covers', eg.covers,
                'source', eg.source,
                'additional_information', eg.additional_information,
                'torrents', COALESCE(jsonb_agg(
                    jsonb_strip_nulls(jsonb_build_object(
                        'id', ft.id, 'upload_factor', ft.upload_factor, 'download_factor', ft.download_factor,
                        'seeders', ft.seeders, 'leechers', ft.leechers, 'completed', ft.completed,
                        'edition_group_id', ft.edition_group_id, 'created_at', ft.created_at,
                        'release_name', ft.release_name, 'release_group', ft.release_group,
                        'file_amount_per_type', ft.file_amount_per_type, 'trumpable', ft.trumpable,
                        'staff_checked', ft.staff_checked, 'languages', ft.languages,
                        'container', ft.container, 'size', ft.size, 'duration', ft.duration,
                        'audio_codec', ft.audio_codec, 'audio_bitrate', ft.audio_bitrate,
                        'audio_bitrate_sampling', ft.audio_bitrate_sampling, 'audio_channels', ft.audio_channels,
                        'video_codec', ft.video_codec, 'features', ft.features,
                        'subtitle_languages', ft.subtitle_languages, 'video_resolution', ft.video_resolution,
                        'reports', ft.reports, 'snatched_at', ft.snatched_at, 'peer_status', ft.peer_status,
                        'free', ft.free, -- Added the new free field here
                        -- Handle anonymity: show creator info only if requesting user is the uploader or if not anonymous
                        'created_by_id', CASE
                            WHEN ft.uploaded_as_anonymous AND (p_requesting_user_id IS NULL OR ft.created_by_id != p_requesting_user_id) THEN NULL
                            ELSE ft.created_by_id
                        END,
                        'created_by', CASE
                            WHEN ft.uploaded_as_anonymous AND (p_requesting_user_id IS NULL OR ft.created_by_id != p_requesting_user_id) THEN NULL
                            ELSE ft.display_created_by
                        END,
                        'uploaded_as_anonymous', ft.uploaded_as_anonymous
                    )) ORDER BY ft.id
                ) FILTER (WHERE ft.id IS NOT NULL), '[]'::jsonb)
            )) AS eg_data,
            MIN(ft.created_at) AS min_torrent_created_at,
            MAX(ft.created_at) AS max_torrent_created_at,
            MIN(ft.size) AS min_torrent_size,
            MAX(ft.size) AS max_torrent_size,
            MIN(ft.snatched_at) AS min_torrent_snatched_at,
            MAX(ft.snatched_at) AS max_torrent_snatched_at
        FROM edition_groups eg
        LEFT JOIN filtered_torrents ft ON eg.id = ft.edition_group_id
        GROUP BY eg.id
    ),
    title_groups_with_relevance AS (
        SELECT
            tg.id,
            tg.name,
            tg.covers,
            tg.category,
            tg.content_type,
            tg.tags,
            tg.original_release_date,
            CASE
                WHEN p_title_group_name IS NOT NULL AND p_title_group_name <> '' THEN
                    ts_rank_cd(to_tsvector('simple', tg.name || ' ' || coalesce(array_to_string(tg.name_aliases, ' '), '')), plainto_tsquery('simple', p_title_group_name))
                ELSE NULL
            END AS relevance_score,
            to_tsvector('simple', tg.name || ' ' || coalesce(array_to_string(tg.name_aliases, ' '), '')) AS search_vector
        FROM title_groups tg
        WHERE p_title_group_name = '' OR to_tsvector('simple', tg.name || ' ' || coalesce(array_to_string(tg.name_aliases, ' '), '')) @@ plainto_tsquery('simple', p_title_group_name)
    ),
    affiliated_artists_data AS (
        SELECT
            aa.title_group_id,
            jsonb_agg(
                jsonb_build_object(
                    'id', ar.id,
                    'name', ar.name
                ) ORDER BY ar.name
            ) AS affiliated_artists
        FROM affiliated_artists aa
        JOIN artists ar ON aa.artist_id = ar.id
        GROUP BY aa.title_group_id
    )
    SELECT
        tgr.id AS title_group_id,
        jsonb_strip_nulls(jsonb_build_object(
            'id', tgr.id,
            'name', tgr.name,
            'covers', tgr.covers,
            'category', tgr.category,
            'content_type', tgr.content_type,
            'tags', tgr.tags,
            'original_release_date', tgr.original_release_date
        ) || jsonb_build_object(
            'edition_groups', COALESCE(jsonb_agg(egwt.eg_data ORDER BY egwt.eg_id) FILTER (WHERE egwt.eg_data IS NOT NULL), '[]'::jsonb),
            'affiliated_artists', COALESCE(aad.affiliated_artists, '[]'::jsonb)
        )) AS title_group_data
    FROM title_groups_with_relevance tgr
    LEFT JOIN edition_groups_with_torrents egwt ON tgr.id = egwt.title_group_id
    LEFT JOIN affiliated_artists_data aad ON tgr.id = aad.title_group_id
    WHERE (p_include_empty_groups = TRUE OR (egwt.eg_data IS NOT NULL AND (egwt.eg_data -> 'torrents')::jsonb <> '[]'::jsonb))
    GROUP BY
        tgr.id, tgr.name, tgr.covers, tgr.category, tgr.content_type, tgr.tags, tgr.original_release_date, tgr.relevance_score, aad.affiliated_artists
    ORDER BY
        CASE
            WHEN p_sort_by = 'relevance' AND p_order = 'asc' THEN tgr.relevance_score
            ELSE NULL
        END ASC NULLS LAST,
        CASE
            WHEN p_sort_by = 'relevance' AND p_order = 'desc' THEN tgr.relevance_score
            ELSE NULL
        END DESC NULLS LAST,
        CASE
            WHEN p_sort_by = 'torrent_created_at' AND p_order = 'asc' THEN MIN(egwt.min_torrent_created_at)
            ELSE NULL
        END ASC NULLS LAST,
        CASE
            WHEN p_sort_by = 'torrent_created_at' AND p_order = 'desc' THEN MAX(egwt.max_torrent_created_at)
            ELSE NULL
        END DESC NULLS LAST,
        CASE
            WHEN p_sort_by = 'torrent_size' AND p_order = 'asc' THEN MIN(egwt.min_torrent_size)
            ELSE NULL
        END ASC NULLS LAST,
        CASE
            WHEN p_sort_by = 'torrent_size' AND p_order = 'desc' THEN MAX(egwt.max_torrent_size)
            ELSE NULL
        END DESC NULLS LAST,
        CASE
            WHEN p_sort_by = 'torrent_snatched_at' AND p_order = 'asc' THEN MAX(egwt.max_torrent_snatched_at)
            ELSE NULL
        END ASC NULLS LAST,
        CASE
            WHEN p_sort_by = 'torrent_snatched_at' AND p_order = 'desc' THEN MAX(egwt.max_torrent_snatched_at)
            ELSE NULL
        END DESC NULLS LAST,
        CASE
            WHEN p_sort_by = 'title_group_original_release_date' AND p_order = 'asc' THEN tgr.original_release_date
            ELSE NULL
        END ASC NULLS LAST,
        CASE
            WHEN p_sort_by = 'title_group_original_release_date' AND p_order = 'desc' THEN tgr.original_release_date
            ELSE NULL
        END DESC NULLS LAST,
        tgr.id ASC
    LIMIT p_limit OFFSET p_offset;
END;
$$;
