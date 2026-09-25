defmodule Market.UpdateCoordinatorTest do
	use ExUnit.Case, async: false

	setup do
		server = :"update_coordinator_#{System.unique_integer([:positive])}"
		start_supervised!({Market.UpdateCoordinator, name: server, cycle_timeout: 100})
		:ok = Market.UpdateCoordinator.subscribe(self(), server)
		{:ok, server: server}
	end

	test "emits one success event when every page completes", %{server: server} do
		Market.UpdateCoordinator.page_started(1, 1, server)
		Market.UpdateCoordinator.page_result(1, 1, :updated, %{pages: 2}, server)
		Market.UpdateCoordinator.page_started(1, 2, server)
		Market.UpdateCoordinator.page_result(1, 2, :not_modified, %{pages: 2}, server)

		assert_receive {:region_refresh_complete, summary}
		assert summary == %{region: 1, pages: 2, updated_pages: [1]}
		refute_receive {:region_refresh_complete, _summary}, 150
	end

	test "does not emit for an all-not-modified cycle", %{server: server} do
		Market.UpdateCoordinator.page_started(2, 1, server)
		Market.UpdateCoordinator.page_result(2, 1, :not_modified, %{pages: 1}, server)

		refute_receive {:region_refresh_complete, _summary}, 150
	end

	test "emits a failure when any page fails", %{server: server} do
		Market.UpdateCoordinator.page_started(3, 1, server)
		Market.UpdateCoordinator.page_result(3, 1, :failed, %{pages: 2, reason: :timeout}, server)
		Market.UpdateCoordinator.page_started(3, 2, server)
		Market.UpdateCoordinator.page_result(3, 2, :updated, %{pages: 2}, server)

		assert_receive {:region_refresh_failed, summary}
		assert summary.region == 3
		assert summary.pages == 2
		assert summary.failures == [%{page: 1, reason: :timeout}]
	end

	test "ignores duplicate results after a cycle has completed", %{server: server} do
		Market.UpdateCoordinator.page_started(4, 1, server)
		Market.UpdateCoordinator.page_result(4, 1, :updated, %{pages: 1}, server)
		assert_receive {:region_refresh_complete, _summary}

		Market.UpdateCoordinator.page_result(4, 1, :updated, %{pages: 1}, server)
		refute_receive {:region_refresh_complete, _summary}, 150

		Market.UpdateCoordinator.page_started(4, 1, server)
		Market.UpdateCoordinator.page_result(4, 1, :updated, %{pages: 1}, server)
		assert_receive {:region_refresh_complete, _summary}
	end

	test "updates the expected page set when the region count changes", %{server: server} do
		Market.UpdateCoordinator.page_started(5, 1, server)
		Market.UpdateCoordinator.page_result(5, 1, :updated, %{pages: 3}, server)
		Market.UpdateCoordinator.page_count(5, 1, server)

		assert_receive {:region_refresh_complete, %{pages: 1}}
	end

	test "fails a cycle that does not finish before its deadline", %{server: server} do
		Market.UpdateCoordinator.page_started(6, 1, server)
		Market.UpdateCoordinator.page_result(6, 1, :updated, %{pages: 2}, server)

		assert_receive {:region_refresh_failed, summary}, 250
		assert summary.region == 6
		assert summary.failures == [%{page: nil, reason: :cycle_timeout}]
	end
end
