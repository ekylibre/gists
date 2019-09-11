list = { 1453 => 178, 1444 => 169, 1560 => 196, 1451 => 176, 1448 => 173, 1862 => 207 }

def delete(todel)
  excs = []
  todel.each do |lp_id, prod_id|
    begin
      lp = LandParcel.find_by(id: lp_id)
      if lp
        def lp.destroyable?
          true
        end
        lp.destroy!
      end
    rescue
      excs << $!
      next
    end

    begin
      prod = ActivityProduction.find_by(id: prod_id)
      prod.destroy! if prod
    rescue
      excs << $!
      next
    end
  end

  excs
end

exceptions = delete(list)
remaining_land_parcels = list.map(&:first).select { |k| LandParcel.find_by(id: k).present? }
remaining_activity_productions = list.map(&:last).select { |j| ActivityProduction.find_by(id: j).present? }
