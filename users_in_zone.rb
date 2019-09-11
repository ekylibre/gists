def users_in_zone(user_export_name, containing_zone_geom, geocoder_id: nil, geocoder_token: nil)
  csv = CSV.open(user_export_name, col_sep: ?;, headers: true)
  adressed, geoloced = csv.tap(&:rewind).group_by { |e| e['Longitude'].present?.to_s }.sort_by(&:first).to_h.values

  quoted_geom = "ST_GeomFromEWKT(#{
    ActiveRecord::Base.connection.quote(containing_zone_geom.to_ewkt)
  })"
  flattened_geom = Charta.new_geometry(ActiveRecord::Base.connection.execute("
    SELECT ST_AsGeoJSON(ST_Union(ST_GeometryN(#{quoted_geom}, geoms.num))) AS geom
      FROM (
        SELECT generate_series(1, ST_NumGeometries(#{quoted_geom}))
      ) AS geoms (num)
  ").to_a.first['geom'])
  containing_query = "ST_GeomFromEWKT(#{ActiveRecord::Base.connection.quote(flattened_geom.to_ewkt)})"

  chartad = geoloced.map do |g|
    [
      g["Ferme"],
      Charta.new_geometry(
        %({ "type": "Point",
            "coordinates":[#{g["Longitude"]}, #{g["Latitude"]}]
          })
      )
    ]
  end

  if geocoder_id && geocoder_token
    chartad += adressed.map do |g|
      unless g['Adresse']
        next
      end
      address = ActiveSupport::Inflector.transliterate(g["Adresse"].unicode_normalize)
      geocoding_url = "https://geocoder.api.here.com/6.2/geocode.json?app_id=#{geocoder_id}&app_code=#{geocoder_token}&searchtext=#{address}"
      geocoded = Net::HTTP.get(URI(geocoding_url))

      coords = JSON(geocoded)
      coords &&= coords["Response"]
      coords &&= coords["View"]
      coords &&= coords[0]
      coords &&= coords["Result"]
      coords &&= coords[0]
      coords &&= coords["Location"]
      coords &&= coords["DisplayPosition"]
      next unless coords && coords["Latitude"].present?
      [
        g["Ferme"],
        Charta.new_geometry(
          %({ "type": "Point",
              "coordinates": [#{coords["Longitude"]}, #{coords["Latitude"]}]
            })
        )
      ]
    end.compact
  end
  query = "(VALUES " + chartad.map { |c, g| "(#{ActiveRecord::Base.connection.quote(c)}, #{ActiveRecord::Base.connection.quote(g.to_ewkt)})" }.join(", ") + ") AS points (farm_name, ewkt_geom)"

  farms_in_zone = ActiveRecord::Base.connection.execute("SELECT farm_name FROM #{query} WHERE ST_Contains(#{containing_query}, ST_GeomFromEWKT(points.ewkt_geom))").to_a
  farms_in_zone.map! { |f| f['farm_name'] }
  csv.tap(&:rewind).select { |c| c['Ferme'].in? farms_in_zone }
end

# user_export_name should be the path to an export similar to coord_export's result
users = users_in_zone(user_export_name, Charta.new_geometry(File.read(geom_source_path)), geocoder_id: ENV['GEOCODER_ID'], geocoder_token: ENV['GEOCODER_TOKEN'])

# Export to CSV afterwards
CSV.open('out.csv', 'wb', col_sep: ?;) { |c| c << users.map(&:to_h).first.keys; users.map(&:to_h).map(&:values).each { |v| c << v } }
