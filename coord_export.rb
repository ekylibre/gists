require 'csv'
require 'sshkit'
require 'colored'
require 'google_drive'

class CoordExport
  extend SSHKit::DSL

  class << self
    def run
      export
      push_to_drive
    end

    def export
      clicnfarm_export
      ekylibre_export
      email_export
      merge_exports
      merge_emails
    end

    def push_to_drive
      return unless @final_export
      config = OpenStruct.new({
        "client_id": "<CLIENT_ID>",
        "client_secret": "<SECRET>",
        "scope": [
          "https://www.googleapis.com/auth/drive",
          "https://spreadsheets.google.com/feeds/"
        ],
        "refresh_token": "<REFRESH_TOKEN>"
      })
      session = GoogleDrive::Session.from_config(config)
      destination_folder = session.file_by_name("Communication").file_by_name("Geoloc Users")
      puts "Uploading to Drive as #{@final_export}...".blue
      destination_folder.upload_from_file("/tmp/#{@final_export}", @final_export, convert: false)
      puts "Upload complete!".blue
    end

    def clicnfarm_export
      on 'mb-prod' do
        within('prod-current') do
          execute :bundle, :exec, 'rails runner -e production "'+<<-RUBY+'"'

            csv = CSV.generate(col_sep: ?;) do |c|
              address_sql_expression = <<-SQL
                entity_addresses.mail_line_1
                  || entity_addresses.mail_line_2
                  || entity_addresses.mail_line_3
                  || entity_addresses.mail_line_4
                  || entity_addresses.mail_line_5
                  || entity_addresses.mail_line_6
              SQL
              entities = Entity.where(of_company: true)
                               .joins(:farm, :default_mail_address)
                               .where('entity_addresses.farm_id = entities.farm_id')
              entity_addresses = entities.pluck('farms.name AS farm,' +
                                                 address_sql_expression + ' AS address')
                                         .map{|(f,a)| [f, { address: a }] }

              centroid_sql_expression = <<-SQL
                ST_Centroid(ST_CollectionExtract(ST_Collect(plots.shape), 3))
              SQL

              plots = Plot.group('farms.name').joins(:farm)
              plot_addresses = plots.pluck('farms.name AS farm,' +
                                           centroid_sql_expression + ' AS centroid')
                                    .map { |(f, c)| [f, { coordinates: c }] }

              addresses = entity_addresses + plot_addresses
              merged_addresses = addresses.group_by(&:first)
                                         .map do |k, v|
                h = v.map(&:last).reduce(&:merge)
                full_keyed = {address: nil, coordinates: nil}.merge(h)
                [k, full_keyed]
              end.to_h

              without_empty = merged_addresses
                .reject { |k,v| v.values.compact.empty? }
                .map do |k,v|
                  h = v.dup
                  h[:coordinates] &&= [h[:coordinates].x, h[:coordinates].y]
                  [k, h]
                end.to_h

              with_splatted_coords = without_empty.map { |k, v| [k, v[:address], *v[:coordinates]] }

              with_splatted_coords.each { |l| c << l }
            end
            File.write('tmp/clicnfarm_export.csv', csv)
          RUBY
          download! 'tmp/clicnfarm_export.csv', '/tmp/clicnfarm_export.csv'
        end
      end
    end

    def ekylibre_export
      on 'eky-prod' do
        within 'prod-current' do
          execute :bundle, :exec, 'rails runner -e production "'+<<-RUBY+'"'

            csv = CSV.generate(col_sep: ?;) do |c|
              existing_list = Ekylibre::Tenant.list.reject do |t|
                begin
                  Ekylibre::Tenant.switch! t
                  false
                rescue
                  true
                end
              end

              list = existing_list.map do |t|
                Ekylibre::Tenant.switch! t
                entity_address = Entity.of_company &&
                                 Entity.of_company.default_mail_address &&
                                 Entity.of_company.default_mail_address.mail_lines

                coordinate_sql_expression = <<-SQL
                ST_AsGeoJSON(
                  ST_Centroid(
                    ST_CollectionExtract(
                      ST_Collect(
                        ST_MakeValid(products.initial_shape)
                      ), 3)))
                SQL
                query = LandParcel.select(coordinate_sql_expression + ' AS centroid').reorder('').to_sql
                coordinates = ActiveRecord::Base.connection.execute(query).first['centroid']
                [t, { address: entity_address, coordinates: coordinates }]
              end.to_h

              without_empty = list.reject { |k,v| v.values.compact.empty? }

              coordinates_ready = without_empty.map do |k,v|
                h = v.dup
                h[:coordinates] &&= eval(h[:coordinates])[:coordinates]
                [k, h]
              end.to_h

              splatted = coordinates_ready.map { |k, v| [k, v[:address], *v[:coordinates]] }

              splatted.each { |l| c << l }
            end
            File.write('tmp/ekylibre_export.csv', csv)
          RUBY

          download! "tmp/ekylibre_export.csv", "/tmp/ekylibre_export.csv"
        end
      end
    end

    def email_export
      on 'mb-prod' do
        within 'prod-current' do
          execute :bundle, :exec, 'rails runner -e production "'+<<-RUBY+'"'

            csv = CSV.generate(col_sep: ?;) do |c|
              emails = Farm.joins(:owner).pluck('users.email AS owner, farms.name AS farm')
              emails.each { |l| c << l }
            end
            File.write('tmp/farm_names.csv', csv)
          RUBY

          download! "tmp/farm_names.csv", "/tmp/farm_names.csv"
        end
      end
    end

    def merge_exports
      csv = CSV.generate(col_sep: ?;) do |c|
        headers = [[:Ferme, :Adresse, :Longitude, :Latitude, :Plateforme]]
        ekylibre = CSV.read('/tmp/ekylibre_export.csv', col_sep: ?;)
        padded_eky = ekylibre.map { |a| (a + [nil, nil])[0..3] + ["EKYLIBRE"] }
        clicnfarm = CSV.read('/tmp/clicnfarm_export.csv', col_sep: ?;)
        padded_cnf = clicnfarm.map { |a| (a + [nil, nil])[0..3] + ['CLIC&FARM'] }

        (headers + padded_eky + padded_cnf).each{ |l| c << l }
      end
      File.write("/tmp/merged_export.csv", csv)
    end

    def merge_emails
      csv = CSV.generate(col_sep: ?;) do |c|
        merged = CSV.read('/tmp/merged_export.csv', col_sep: ?;)

        merged_headers = merged[0][0..-1]
        new_headers = [merged_headers + ['Email']]

        farm_names = CSV.read('/tmp/farm_names.csv', col_sep: ?;)
        merged_body = merged[1..-1]

        new_body = merged_body.map do |r|
          matching_farm = farm_names.find { |l| l.last == r.first }&.first
          [*r, matching_farm]
        end

        new_csv = new_headers + new_body
        new_csv.each { |l| c << l }
      end

      @final_export = "export_#{DateTime.now.strftime("%Y-%m-%d — %H:%M")}.csv"
      File.write("/tmp/#{@final_export}", csv)
    end
  end
end
