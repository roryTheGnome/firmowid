defmodule Firmowid.Timetracker.ProjectTest do
  use Firmowid.DataCase, async: true

  import Firmowid.AccountsFixtures
  import Firmowid.TimetrackerFixtures

  alias Ash.Error.Changes.InvalidChanges
  alias Ash.Error.Forbidden
  alias Ash.Error.Invalid
  alias Firmowid.Analysis.TagDefinition
  alias Firmowid.Core
  alias Firmowid.Timetracker.Project

  require Ash.Query

  setup :setup_scope

  describe "create/2" do
    test "creates a project", %{scope: scope} do
      {:ok, project} = Project.create(%{name: "Test Project"}, scope: scope)

      assert project.name == "Test Project"
      assert is_nil(project.archived_at)
    end

    test "creates a project with assigned members", %{user: user, org_id: org_id, scope: scope} do
      user2 = user_in_org_fixture(org_id)

      {:ok, project} =
        Project.create(
          %{name: "Assigned Project", member_ids: [user.member.id, user2.member.id]},
          scope: scope
        )

      project = Ash.load!(project, [:members], scope: scope)
      active_ids = project.members |> Enum.map(& &1.user_id) |> Enum.sort()

      assert active_ids == Enum.sort([user.id, user2.id])
    end
  end

  describe "archive + unarchive" do
    test "archives and unarchives a project", %{scope: scope} do
      project = project_fixture(%{organization_id: scope.tenant})

      {:ok, archived} = Project.archive(project, scope: scope)
      assert archived.archived_at

      {:ok, restored} = Project.unarchive(archived, scope: scope)
      assert is_nil(restored.archived_at)
    end
  end

  describe "organization owner deletion" do
    test "destroys project-created tag definitions before deleting the account", %{
      user: admin,
      org_id: org_id,
      scope: scope
    } do
      {:ok, project} = Project.create(%{name: "Project Cleanup"}, scope: scope)

      assert project.tag_definition_id
      assert :ok = Core.destroy_user(admin, scope: %{scope | actor: with_session_claims(admin)})

      refute Core.User
             |> Ash.Query.filter(id == ^admin.id)
             |> Ash.exists?(authorize?: false)

      refute Core.Organization
             |> Ash.Query.filter(id == ^org_id)
             |> Ash.exists?(authorize?: false)

      refute Project
             |> Ash.Query.filter(id == ^project.id)
             |> Ash.exists?(actor: admin, authorize?: false, tenant: org_id)

      refute TagDefinition
             |> Ash.Query.filter(id == ^project.tag_definition_id)
             |> Ash.exists?(actor: admin, authorize?: false, tenant: org_id)
    end

    test "rolls back account deletion when the surrounding transaction aborts", %{
      user: admin,
      org_id: org_id,
      scope: scope
    } do
      {:ok, project} = Project.create(%{name: "Rollback Project"}, scope: scope)

      assert {:error, %Ash.Error.Unknown.UnknownError{error: "unknown error: :forced_rollback"}} =
               Ash.transact([Core.User, Core.Organization, Project, TagDefinition], fn ->
                 assert :ok =
                          Core.destroy_user_in_transaction(admin,
                            scope: %{scope | actor: with_session_claims(admin)}
                          )

                 Ash.DataLayer.rollback(Core.User, :forced_rollback)
               end)

      assert Core.User
             |> Ash.Query.filter(id == ^admin.id)
             |> Ash.exists?(authorize?: false)

      assert Core.Organization
             |> Ash.Query.filter(id == ^org_id)
             |> Ash.exists?(authorize?: false)

      assert Project
             |> Ash.Query.filter(id == ^project.id)
             |> Ash.exists?(actor: admin, authorize?: false, tenant: org_id)

      assert TagDefinition
             |> Ash.Query.filter(id == ^project.tag_definition_id)
             |> Ash.exists?(actor: admin, authorize?: false, tenant: org_id)
    end
  end

  describe "budget" do
    test "requires scope when a budget is set", %{scope: scope} do
      assert {:error, %Invalid{errors: errors}} =
               Project.create(%{name: "Budget Project", budget_kind: :hours}, scope: scope)

      assert Enum.any?(errors, &match?(%{field: :budget_scope}, &1))
    end

    test "requires a limit when a budget is set", %{scope: scope} do
      assert {:error, %Invalid{errors: errors}} =
               Project.create(
                 %{name: "Budget Project", budget_kind: :hours, budget_scope: :monthly},
                 scope: scope
               )

      assert Enum.any?(errors, &match?(%{field: :budget_limit}, &1))
    end

    test "rejects budget fields without a budget kind", %{scope: scope} do
      assert {:error,
              %Invalid{
                errors: [
                  %InvalidChanges{
                    message: "budget scope, limit and engagement dates must be empty without a budget"
                  }
                ]
              }} =
               Project.create(%{name: "Orphan Limit", budget_limit: Decimal.new("10")},
                 scope: scope
               )
    end

    test "strips engagement dates when the scope is monthly", %{scope: scope} do
      project = project_fixture(%{organization_id: scope.tenant})

      {:ok, project} =
        Project.update(
          project,
          %{
            budget_kind: :hours,
            budget_scope: :monthly,
            budget_limit: Decimal.new("10"),
            budget_engagement_starts_on: ~D[2026-11-01]
          },
          scope: scope
        )

      assert is_nil(project.budget_engagement_starts_on)
    end

    test "requires engagement dates for engagement budgets", %{scope: scope} do
      assert {:error, %Invalid{errors: errors}} =
               Project.create(
                 %{
                   name: "Engagement Budget",
                   budget_kind: :hours,
                   budget_scope: :engagement,
                   budget_limit: Decimal.new("10")
                 },
                 scope: scope
               )

      assert Enum.any?(errors, &match?(%{field: :budget_engagement_starts_on}, &1))
    end

    test "rejects engagement periods that end before they start", %{scope: scope} do
      assert {:error, %Invalid{errors: errors}} =
               Project.create(
                 %{
                   name: "Backwards Engagement",
                   budget_kind: :hours,
                   budget_scope: :engagement,
                   budget_limit: Decimal.new("10"),
                   budget_engagement_starts_on: ~D[2026-11-15],
                   budget_engagement_ends_on: ~D[2026-11-01]
                 },
                 scope: scope
               )

      assert Enum.any?(errors, &match?(%{field: :budget_engagement_ends_on}, &1))
    end

    test "clears budget fields when the budget is removed", %{scope: scope} do
      project = project_fixture(%{organization_id: scope.tenant})

      {:ok, project} =
        Project.update(
          project,
          %{
            budget_kind: :hours,
            budget_scope: :monthly,
            budget_limit: Decimal.new("10")
          },
          scope: scope
        )

      {:ok, project} = Project.update(project, %{budget_kind: nil}, scope: scope)

      assert is_nil(project.budget_scope)
      assert is_nil(project.budget_limit)
    end

    test "clears engagement dates when the scope is monthly", %{scope: scope} do
      project = project_fixture(%{organization_id: scope.tenant})

      {:ok, project} =
        Project.update(
          project,
          %{
            budget_kind: :hours,
            budget_scope: :engagement,
            budget_limit: Decimal.new("10"),
            budget_engagement_starts_on: ~D[2026-11-01],
            budget_engagement_ends_on: ~D[2026-11-30]
          },
          scope: scope
        )

      {:ok, project} = Project.update(project, %{budget_scope: :monthly}, scope: scope)

      assert is_nil(project.budget_engagement_starts_on)
      assert is_nil(project.budget_engagement_ends_on)
    end

    test "hides budget fields from project members", %{org_id: org_id, scope: scope} do
      member = user_in_org_fixture(org_id)

      {:ok, project} =
        Project.create(
          %{
            name: "Budget Project",
            budget_kind: :hours,
            budget_scope: :monthly,
            budget_limit: Decimal.new("10"),
            member_ids: [member.member.id]
          },
          scope: scope
        )

      member_scope = %Firmowid.Scope{actor: member, tenant: org_id}
      member_project = Ash.get!(Project, project.id, scope: member_scope, load: false)

      assert %Ash.ForbiddenField{} = member_project.budget_kind
      assert %Ash.ForbiddenField{} = member_project.budget_limit
    end

    test "forbids non-admins from changing budget settings", %{org_id: org_id, scope: scope} do
      member = user_in_org_fixture(org_id)

      {:ok, project} =
        Project.create(%{name: "Member Project", member_ids: [member.member.id]}, scope: scope)

      member_scope = %Firmowid.Scope{actor: member, tenant: org_id}

      assert {:error, %Forbidden{}} =
               Project.update(project, %{budget_limit: Decimal.new("20")}, scope: member_scope)
    end
  end

  describe "update/3" do
    test "replaces assigned members", %{user: user, org_id: org_id, scope: scope} do
      project = project_fixture(%{organization_id: org_id})
      user2 = user_in_org_fixture(org_id)
      user3 = user_in_org_fixture(org_id)

      {:ok, _} =
        Project.update(project, %{member_ids: [user.member.id, user2.member.id]}, scope: scope)

      {:ok, _} = Project.update(project, %{member_ids: [user3.member.id]}, scope: scope)

      project_with_members = Project.get!(project.id, scope: scope)
      active_ids = project_with_members.members |> Enum.map(& &1.user_id) |> Enum.sort()

      assert active_ids == [user3.id]
    end
  end

  defp setup_scope(_) do
    admin = admin_fixture()
    org_id = admin.member.organization_id

    scope = %Firmowid.Scope{
      actor: admin,
      tenant: org_id
    }

    %{user: admin, org_id: org_id, scope: scope}
  end
end
