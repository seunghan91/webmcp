class PagesController < ApplicationController
  def a
    @tools = %i[items_read items_create redirect_read redirect_write boom string_tool]
  end

  def b
    @tools = %i[items_read string_tool]
    # A different transport changes every fingerprint, so page B re-registers
    # items_read and string_tool under the same names (same-name re-registration).
    @transport = { csrf: { source: "meta", name: "csrf-token", header: "X-CSRF-Token-Page-B" } }
  end

  # No manifest at all, like a sign-in page that a Turbo visit leaves for page A.
  def empty
    @tools = []
  end
end
