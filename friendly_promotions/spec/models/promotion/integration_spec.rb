# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Promotion System" do
  context "A promotion that creates line item adjustments" do
    let(:shirt) { create(:product, name: "Shirt") }
    let(:pants) { create(:product, name: "Pants") }
    let(:promotion) { create(:friendly_promotion, name: "20% off Shirts", apply_automatically: true) }
    let(:order) { create(:order) }

    before do
      promotion.rules << rule
      promotion.actions << action
      order.contents.add(shirt.master, 1)
      order.contents.add(pants.master, 1)
    end

    context "with an order-level rule" do
      let(:rule) { SolidusFriendlyPromotions::Rules::Product.new(products: [shirt], preferred_line_item_applicable: false) }

      context "with an line item level action" do
        let(:calculator) { SolidusFriendlyPromotions::Calculators::Percent.new(preferred_percent: 20) }
        let(:action) { SolidusFriendlyPromotions::Actions::AdjustLineItem.new(calculator: calculator) }

        it "creates one line item level adjustment" do
          expect(order.adjustments).to be_empty
          expect(order.total).to eq(31.98)
          expect(order.item_total).to eq(39.98)
          expect(order.item_total_before_tax).to eq(31.98)
          expect(order.line_items.flat_map(&:adjustments).length).to eq(2)
        end
      end
    end

    context "with a line-item level rule" do
      let(:rule) { SolidusFriendlyPromotions::Rules::LineItemProduct.new(products: [shirt]) }

      context "with an line item level action" do
        let(:calculator) { SolidusFriendlyPromotions::Calculators::Percent.new(preferred_percent: 20) }
        let(:action) { SolidusFriendlyPromotions::Actions::AdjustLineItem.new(calculator: calculator) }

        it "creates one line item level adjustment" do
          expect(order.adjustments).to be_empty
          expect(order.total).to eq(35.98)
          expect(order.item_total).to eq(39.98)
          expect(order.item_total_before_tax).to eq(35.98)
          expect(order.line_items.flat_map(&:adjustments).length).to eq(1)
        end
      end
    end
  end

  context "with two promotions that should stack" do
    let(:shirt) { create(:product, name: "Shirt", price: 30) }
    let(:pants) { create(:product, name: "Pants", price: 40) }
    let(:discounted_item_total_rule_amount) { 60 }
    let(:discounted_item_total_rule) do
      SolidusFriendlyPromotions::Rules::DiscountedItemTotal.new(preferred_amount: discounted_item_total_rule_amount)
    end

    let!(:distributed_amount_promo) do
      create(:friendly_promotion,
        :with_adjustable_action,
        preferred_amount: 10.0,
        apply_automatically: true,
        rules: [discounted_item_total_rule],
        lane: :post,
        calculator_class: SolidusFriendlyPromotions::Calculators::DistributedAmount)
    end
    let(:shirts_rule) { SolidusFriendlyPromotions::Rules::LineItemProduct.new(products: [shirt]) }
    let(:shirts_calculator) { SolidusFriendlyPromotions::Calculators::Percent.new(preferred_percent: 20) }
    let(:shirts_action) { SolidusFriendlyPromotions::Actions::AdjustLineItem.new(calculator: shirts_calculator) }
    let!(:shirts_promotion) do
      create(
        :friendly_promotion,
        rules: [shirts_rule],
        actions: [shirts_action],
        name: "20% off shirts",
        apply_automatically: true
      )
    end
    let(:order) { create(:order) }

    before do
      order.contents.add(shirt.master, 1)
      order.contents.add(pants.master, 1)
    end

    it "does all the right things" do
      expect(order.adjustments).to be_empty
      # shirt: 30 USD - 20% = 24 USD
      # Remaining total: 64 USD
      # 10 USD distributed off: 54 USD
      expect(order.total).to eq(54.00)
      expect(order.item_total).to eq(70.00)
      expect(order.item_total_before_tax).to eq(54)
      expect(order.line_items.flat_map(&:adjustments).length).to eq(3)
    end

    context "if the post lane promotion is ineligible" do
      let(:discounted_item_total_rule_amount) { 68 }

      it "does all the right things" do
        expect(order.adjustments).to be_empty
        # shirt: 30 USD - 20% = 24 USD
        # Remaining total: 64 USD
        # The 10 off promotion does not apply because now the order total is below 68
        expect(order.total).to eq(64.00)
        expect(order.item_total).to eq(70.00)
        expect(order.item_total_before_tax).to eq(64)
        expect(order.line_items.flat_map(&:adjustments).length).to eq(1)
      end
    end
  end

  context "with a shipment-level rule" do
    let!(:address) { create(:address) }
    let(:shipping_zone) { create(:global_zone) }
    let(:store) { create(:store) }
    let!(:ups_ground) { create(:shipping_method, zones: [shipping_zone], cost: 23) }
    let!(:dhl_saver) { create(:shipping_method, zones: [shipping_zone], cost: 37) }
    let(:variant) { create(:variant, price: 13) }
    let(:promotion) { create(:friendly_promotion, name: "20 percent off UPS Ground", apply_automatically: true) }
    let(:rule) { SolidusFriendlyPromotions::Rules::ShippingMethod.new(preferred_shipping_method_ids: [ups_ground.id]) }
    let(:order) { Spree::Order.create!(store: store) }

    before do
      promotion.rules << rule
      promotion.actions << action

      order.contents.add(variant, 1)
      order.ship_address = address
      order.bill_address = address

      order.create_proposed_shipments

      order.shipments.first.selected_shipping_rate_id = order.shipments.first.shipping_rates.detect do |r|
        r.shipping_method == shipping_method
      end.id

      order.recalculate
    end

    context "with a line item level action" do
      let(:calculator) { SolidusFriendlyPromotions::Calculators::Percent.new(preferred_percent: 20) }
      let(:action) { SolidusFriendlyPromotions::Actions::AdjustLineItem.new(calculator: calculator) }
      let(:shipping_method) { ups_ground }

      it "creates adjustments" do
        expect(order.adjustments).to be_empty
        expect(order.total).to eq(33.40)
        expect(order.item_total).to eq(13)
        expect(order.item_total_before_tax).to eq(10.40)
        expect(order.promo_total).to eq(-2.60)
        expect(order.line_items.flat_map(&:adjustments).length).to eq(1)
        expect(order.shipments.flat_map(&:adjustments)).to be_empty
        expect(order.shipments.flat_map(&:shipping_rates).flat_map(&:discounts)).to be_empty
      end
    end

    context "with a shipment level action" do
      let(:calculator) { SolidusFriendlyPromotions::Calculators::Percent.new(preferred_percent: 20) }
      let(:action) { SolidusFriendlyPromotions::Actions::AdjustShipment.new(calculator: calculator) }

      context "when the order is eligible" do
        let(:shipping_method) { ups_ground }

        it "creates adjustments" do
          expect(order.adjustments).to be_empty
          expect(order.total).to eq(31.40)
          expect(order.item_total).to eq(13)
          expect(order.item_total_before_tax).to eq(13)
          expect(order.promo_total).to eq(-4.6)
          expect(order.line_items.flat_map(&:adjustments)).to be_empty
          expect(order.shipments.flat_map(&:adjustments)).not_to be_empty
          expect(order.shipments.flat_map(&:shipping_rates).flat_map(&:discounts)).not_to be_empty
        end
      end

      context "when the order is not eligible" do
        let(:shipping_method) { dhl_saver }

        it "creates no adjustments" do
          expect(order.adjustments).to be_empty
          expect(order.total).to eq(50)
          expect(order.item_total).to eq(13)
          expect(order.item_total_before_tax).to eq(13)
          expect(order.promo_total).to eq(0)
          expect(order.line_items.flat_map(&:adjustments)).to be_empty
          expect(order.shipments.flat_map(&:adjustments)).to be_empty
          expect(order.shipments.flat_map(&:shipping_rates).flat_map(&:discounts)).not_to be_empty
        end
      end
    end
  end
end
