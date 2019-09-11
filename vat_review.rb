###################################################################################
###################################################################################
###################################################################################
#####                                                                         #####
#####   Have been hard-coded: the account numbers related to the various      #####
#####   'kinds' of purchases/sales (goods, services, etc), the reference      #####
#####   country ('fr') and the countries in the Euro Tax Community (and       #####
#####   these only due to a lack of a proper nomenclature.                    #####
#####                                                                         #####
#####   Apart from the aformentioned, every tool in here can theoretically    #####
#####   be used in other contexts.                                            #####
#####                                                                         #####
###################################################################################
###################################################################################
###################################################################################

# Set of tools and processes to help reviewing VAT amounts on an Ekylibre instance
module VATReview
  # Helper methods to handle countries and various geographic zones.
  module Geo
    ZONES = %i(inside_france outside_france inside_community outside_community).freeze # Would love a cleaner way to do this.
    COMMUNITY = %i(cz de at be bg cy hr dk es ee fi fr ch gr hu ie it lv lt lu mt nl pl pt ro gb sk si se).freeze # Same here.

    def self.inside_france(items)
      from_countries(items, :fr)
    end

    def self.outside_france(items)
      not_from_countries(items, :fr)
    end

    def self.inside_community(items)
      from_countries(outside_france(items), COMMUNITY)
    end

    def self.outside_community(items)
      not_from_countries(outside_france(items), COMMUNITY)
    end

    def self.from_countries(items, codes)
      filter_countries(items, :select, codes)
    end

    def self.not_from_countries(items, codes)
      filter_countries(items, :reject, codes)
    end

    def self.filter_countries(items, mode, codes)
      codes = [codes] unless codes.respond_to? :include?
      items.first.class.where(id: items.to_a.send(mode) { |it| codes.map(&:to_s).include? Items::Inspecter.country_of(it).to_s }.map(&:id))
    end
    private_class_method :filter_countries
  end

  # Helper methods to handle the various kind of purchases/sales.
  module Kinds
    def self.constants
      super.map { |c| const_get(c) }.select { |c| c.const_defined? :ACCOUNTS }
    end

    # Provides the filter methods to the other modules.
    module Filters
      def filter_from(items)
        from_accounts(items, const_get(:ACCOUNTS)[Items::Inspecter.nature_of(items.first)])
      end

      def from_accounts(items, accounts)
        accounts = [accounts] unless accounts.respond_to? :include?
        items.where(account_id: accounts_for(accounts).pluck(:id))
      end

      private

      def accounts_for(numbers)
        numbers = [numbers] unless numbers.respond_to? :include?
        Account.where(number: numbers)
      end
    end

    # Info describing what items are merchandise
    module Merchandise
      extend Kinds::Filters
      ACCOUNTS = {
        purchase: %i(601 60221 60222 6026 604 60611 60612 60613 6063 606301 606302 6064 6338 63511 63543 658 6712).freeze,
        sale: %i(701).freeze
      }.freeze
    end
    # Info describing what items are services
    module Service
      extend Kinds::Filters
      ACCOUNTS = {
        purchase: %i(611 6132 6135 61353 6152 6155 6156 616 6211 6222 6226 6227 623 6231 6241 6242 6251 6256 6257 626 6261 6275 628 6181).freeze,
        sale: %i(706).freeze
      }.freeze
    end

    # Info describing what items are consigns
    module Consign
      extend Kinds::Filters
      ACCOUNTS = {
        purchase: %i(4096).freeze,
        sale: %i().freeze
      }.freeze
    end

    # Info describing what items are discounts
    module Discount
      extend Kinds::Filters
      ACCOUNTS = {
        purchase: %i().freeze,
        sale: %i(709).freeze
      }.freeze
    end

    # Info describing what items are cost transfers
    module CostTransfer
      extend Kinds::Filters
      ACCOUNTS = {
        purchase: %i().freeze,
        sale: %i(791).freeze
      }.freeze
    end

    # Info describing what items are frozen assets
    module FrozenAsset
      extend Kinds::Filters
      ACCOUNTS = {
        purchase: %i(2182 2154).freeze,
        sale: %i().freeze
      }.freeze
    end

    # Info describing what items are retrocessions
    module Retrocession
      extend Kinds::Filters
      ACCOUNTS = {
        purchase: %i().freeze,
        sale: %i(7088).freeze
      }.freeze
    end
  end

  # Helper methods to handle the items themselves.
  module Items
    # Scopes to filter items.
    module Scopes
      def self.of_tax(items, taxes)
        taxes ||= Accountancy.taxes
        taxes = [taxes] unless taxes.respond_to? :include?
        taxes_id = taxes.map { |tax| tax.respond_to?(:id) ? tax.id : tax }
        items.where(tax_id: taxes_id)
      end

      def self.of_kind(items, kind)
        kind.filter_from(items)
      end

      def self.of_geozone(items, zone)
        Geo.send(zone, items)
      end
    end

    # Methods to fetch items.
    module Finder
      def self.of_october(model, column)
        between(model, Date.civil(2016, 10, 1), Date.civil(2016, 10, 31), column)
      end

      def self.between(model, start, finish, column)
        case model.new
        when SaleItem
          of_parents(find_parents_between(Sale, start, finish, column))
        when PurchaseItem
          of_parents(find_parents_between(Purchase, start, finish, column))
        end
      end

      def self.of_parents(trades)
        trades = trades.includes(:items)
        item_class = trades.first.items.first.class
        item_class.where(id: trades.map(&:items).flatten.map(&:id))
      end

      def self.find_parents_between(model, start, finish, column)
        model.where(model.arel_table[column].gteq(start).and(model.arel_table[column].lteq(finish)))
      end
      private_class_method :find_parents_between
    end

    # Methods to get intel about an item.
    module Inspecter
      def self.resource_of(item)
        case item
        when PurchaseItem then item
        when SaleItem then item
        when JournalEntryItem
          entry.resource_type.constantize.find(entry.resource_id)
        end
      end

      def self.nature_of(item)
        case item
        when JournalEntryItem
          case item.resource_type.constantize.new
          when SaleItem then :sale
          when PurchaseItem then :purchase
          end
        when SaleItem then :sale
        when PurchaseItem then :purchase
        end
      end

      def self.country_of(item)
        case item
        when JournalEntryItem then country_of(resource_of(item))
        when PurchaseItem     then Maybe(item.purchase.supplier).default_mail_address.mail_country.or_else('fr')
        when SaleItem         then Maybe(item.sale).invoice_address.mail_country.or_else('fr')
        end
      end
    end

    # Perform operations on collections of items to get insight.
    module Analysis
      # The methods that actually deal with the amounts.
      module Computations
        def self.count(collection)
          collection.count
        end

        def self.pretax(collection)
          collection.pluck(:pretax_amount)
        end

        def self.pretax_sum(collection)
          collection.sum(:pretax_amount)
        end

        def self.total(collection)
          return collection if collection.blank?
          case collection.first
          when JournalEntryItem
            op = Items::Inspecter.nature_of(collection.first) == :purchase ? :+ : :-
            collection.pluck(:pretax_amount, :balance).map { |values| values.reduce(&op) }
          when SaleItem
            collection.pluck(:amount)
          when PurchaseItem
            collection.pluck(:amount)
          end
        end

        def self.total_sum(collection)
          return 0 if collection.blank?
          case collection.first
          when JournalEntryItem then total(collection).sum
          when SaleItem         then collection.sum(:amount)
          when PurchaseItem     then collection.sum(:amount)
          end
        end

        def self.vat(collection)
          return collection if collection.blank?
          case collection.first
          when JournalEntryItem then collection.sum(:balance).abs
          when SaleItem
            collection.pluck(:amount, :pretax_amount).map { |values| values.reduce(&:-) }.sum
          when PurchaseItem
            collection.pluck(:amount, :pretax_amount).map { |values| values.reduce(&:-) }.sum
          end
        end

        def self.vat_sum(collection)
          return 0 if collection.blank?
          case collection.first
          when JournalEntryItem then collection.sum(:balance).abs
          when SaleItem         then (collection.sum(:amount) - collection.sum(:pretax_amount))
          when PurchaseItem     then (collection.sum(:amount) - collection.sum(:pretax_amount))
          end
        end
      end

      def self.compute(collection)
        [
          Computations.count(collection),
          Computations.pretax_sum(collection).to_f,
          Computations.vat_sum(collection).to_f,
          Computations.total_sum(collection).to_f
        ]
      end

      def self.matches?(set, other)
        compute(set) == compute(other)
      end
    end
  end

  # Helper methods to deal with accountancy-related data.
  module Accountancy
    def self.taxes
      Tax.pluck(:id)
    end

    def self.accountancy_items_for(items)
      JournalEntryItem.where(resource_id: items.pluck(:id), resource_type: items.first.class.name, tax: taxes)
    end
  end

  # Presenter object to handle the displaying.
  class Presenter
    class << self
      def puts(str = '')
        @text ||= []
        @text << str + "\n"
      end

      def clear
        @text = ''
      end

      def show
        print @text
      end

      def display(title, *args)
        puts "- #{title.to_s.upcase}"
        display_stats(*args)
      end

      def matching(matches)
        puts '----------------------'
        if matches
          puts '    💯 MATCHES'
        else
          puts '  ❌ DOESNT MATCH'
        end
        puts '----------------------'
      end

      def title_for(**details, &block)
        process_title details[:process],  &block
        nature_title  details[:nature],   &block
        all_title     details[:all],      &block
        zone_title    details[:zone],     &block
        tax_title     details[:tax],      &block
        kind_title    details[:kind],     &block
      end

      private

      def display_stats(count, pretax, vat, total)
        puts '   - Count    : ' + count.to_s
        puts '   - PreTax   : ' + pretax.to_s
        puts '   - VAT      : ' + vat.to_s
        puts '   - TOTAL    : ' + total.to_s
      end

      def process_title(title)
        return unless title
        puts '==================================='
        puts '===== REVIEWING PROCESS START ====='
        puts '==================================='
        puts

        yield

        puts
        puts '==================================='
        puts '=====     PROCESSING DONE     ====='
        puts '==================================='
      end

      def nature_title(title)
        return unless title
        puts '####################################'
        puts "###### #{title.upcase} ######"
        puts

        yield

        puts
        puts '####################################'
      end

      def all_title(title)
        return unless title
        puts '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
        puts '!!!!! ALL ITEMS !!!!!'
        puts

        yield

        puts
        puts '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
      end

      def zone_title(title)
        return unless title
        puts '||||||||||||||||||||||||||||||||||||'
        puts ">>>>> #{title.upcase} <<<<<"
        puts

        yield

        puts
        puts '||||||||||||||||||||||||||||||||||||'
      end

      def tax_title(title)
        return unless title
        puts '------------------------------------'
        puts "----- TAX: #{title.upcase} -----"
        puts

        yield

        puts
        puts '------------------------------------'
      end

      def kind_title(title)
        return unless title
        puts '+++++++++++++++++++++++++++++++++++'
        puts "+++++ KIND: #{title.upcase} +++++"
        puts

        yield

        puts
        puts '+++++++++++++++++++++++++++++++++++'
      end
    end
  end

  # Smallish-hack to force display through the Presenter.
  module StoresText
    def puts(text)
      Presenter.puts(text)
    end
  end
  include StoresText

  # Object that will orchestrate the reviewing process.
  class Process
    class << self
      def start
        Presenter.title_for(process: true) do
          [SaleItem, PurchaseItem].each { |nature| process_for(nature, Items::Finder.of_october(nature, :invoiced_at)) }
        end
        true
      end

      def process_for(nature, items)
        Presenter.title_for(nature: nature.name) do
          process_all(items)
          Geo::ZONES.each { |zone| process_zone(zone, Items::Scopes.of_geozone(items, zone)) }
          Kinds.constants.each { |kind| process_kind(kind, Items::Scopes.of_kind(items, kind)) }
        end
      end

      def process_all(items)
        Presenter.title_for(all: true) do
          process(items)
        end
      end

      def process_zone(zone, items)
        Presenter.title_for(zone: zone.to_s.humanize) do
          process_tax(nil, items)
          Accountancy.taxes.each { |tax| process_tax(tax, items) }
        end
      end

      def process_kind(kind, items)
        Presenter.title_for(kind: kind.name.split('::').last.to_s.humanize) do
          process(items)
        end
      end

      def process_tax(tax, items)
        title = tax.nil? ? 'all' : Tax.find(tax).name
        Presenter.title_for(tax: title) do
          process Items::Scopes.of_tax(items, tax),
                  Items::Scopes.of_tax(Accountancy.accountancy_items_for(items), tax)
        end
      end

      def process(items, entries = nil)
        entries ||= Accountancy.accountancy_items_for(items)
        Presenter.matching Items::Analysis.matches?(items, entries)
        Presenter.display :items, *Items::Analysis.compute(items)
        Presenter.display :entries, *Items::Analysis.compute(entries)
      end
    end
  end
end

def review_vat
  VATReview::Presenter.clear
  VATReview::Process.start
  VATReview::Presenter.show
end

review_vat
