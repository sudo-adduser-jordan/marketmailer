defmodule Marketmailer.UtilsTest do
	use ExUnit.Case, async: true

	alias Marketmailer.Utils

	describe "isk_compact/1" do
		test "billions and millions keep two decimals" do
			assert Utils.isk_compact(2_500_000_000) == "2.50b"
			assert Utils.isk_compact(4_990_000) == "4.99m"
			assert Utils.isk_compact(1_000_000) == "1.00m"
		end

		test "thousands use one decimal" do
			assert Utils.isk_compact(215_000) == "215.0k"
			assert Utils.isk_compact(1_000) == "1.0k"
		end

		test "amounts below a thousand stay exact" do
			assert Utils.isk_compact(999) == "999.00"
			assert Utils.isk_compact(0) == "0.00"
		end

		test "negatives keep their sign" do
			assert Utils.isk_compact(-215_000) == "-215.0k"
			assert Utils.isk_compact(-1_500_000) == "-1.50m"
		end
	end

	describe "price_value/1" do
		test "compacts every tier" do
			assert Utils.price_value(4_990_000) == "4.99m ISK"
			assert Utils.price_value(215_000) == "215.0k ISK"
			assert Utils.price_value(999) == "999.00 ISK"
		end

		test "keeps a leading minus only for negatives" do
			assert Utils.price_value(-1_500_000) == "-1.50m ISK"
			assert Utils.price_value("2500000") == "2.50m ISK"
		end

		test "unknown prices render a placeholder" do
			assert Utils.price_value(nil) == "? ISK"
			assert Utils.price_value("") == "? ISK"
		end
	end

	describe "margin_value/1" do
		test "signs positive and negative margins" do
			assert Utils.margin_value(-215_000) == "-215.0k ISK"
			assert Utils.margin_value(38_700_000) == "+38.70m ISK"
			assert Utils.margin_value(100) == "+100.00 ISK"
		end

		test "unknown margins render a placeholder" do
			assert Utils.margin_value(nil) == "? ISK"
			assert Utils.margin_value(:nope) == "? ISK"
		end
	end

	describe "margin_percent/2" do
		test "is the return on the sell price" do
			assert Utils.margin_percent(-215_000, 4_990_000) == "-4.3%"
			assert Utils.margin_percent(100, 10) == "+1000.0%"
		end

		test "is unknown without a usable cost" do
			assert Utils.margin_percent(nil, 10) == "?"
			assert Utils.margin_percent(1, nil) == "?"
			assert Utils.margin_percent(1, 0) == "?"
			assert Utils.margin_percent("x", 10) == "?"
		end
	end
end
