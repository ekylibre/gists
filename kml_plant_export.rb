def puts(arg)
  @kml ||= ""
  @kml += arg + "\n"
  print arg + "\n"
end

puts %{<?xml version="1.0" encoding="UTF-8"?>\n<kml xmlns="http://www.opengis.net/kml/2.2"\n xmlns:gx="http://www.google.com/kml/ext/2.2">}
puts "<Document>\n<Folder>"
Plant.all
     .select { |p| Campaign.all.find {|c| p.in? Plant.of_campaign(c) }.name == '2018' }
     .each do |p|
       puts "<Placemark>"
       puts ["<name>#{p.name}</name>",
             "<description>#{p.name}</description>",
             "<ExtendedData>",
               "<Data name=\"activity_name\">",
                 "<displayName>Activité</displayName>",
                 "<value>#{p.activity.name}</value>",
               "</Data>",
               "<Data name=\"campaign\">",
                 "<displayName>Campagne</displayName>",
                 "<value>#{Campaign.all.find { |c| p.in? Plant.of_campaign(c) }.name}</value>",
               "<\/Data>",
             "</ExtendedData>"].join("\n")
       puts RGeo::Kml.encode(p.shape.to_rgeo) + "</Placemark>"
     end
puts "</Folder>"
puts "</Document>"
puts "</kml>"
