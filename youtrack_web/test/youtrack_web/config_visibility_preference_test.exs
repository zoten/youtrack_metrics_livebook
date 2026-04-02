defmodule YoutrackWeb.ConfigVisibilityPreferenceTest do
  use ExUnit.Case, async: true

  alias YoutrackWeb.ConfigVisibilityPreference

  describe "normalize/1" do
    test "accepts boolean values" do
      assert ConfigVisibilityPreference.normalize(true)
      refute ConfigVisibilityPreference.normalize(false)
    end

    test "accepts string boolean values" do
      assert ConfigVisibilityPreference.normalize("true")
      refute ConfigVisibilityPreference.normalize("false")
    end

    test "falls back to default when value is unknown" do
      assert ConfigVisibilityPreference.normalize(nil)
      assert ConfigVisibilityPreference.normalize("1")
      assert ConfigVisibilityPreference.normalize("invalid")
    end
  end
end
