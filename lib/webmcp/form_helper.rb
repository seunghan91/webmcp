# frozen_string_literal: true

module WebMCP
  module FormOptions
    module_function

    def extract(options)
      options = options.dup
      metadata = options.delete(:webmcp) || options.delete("webmcp")
      [options, metadata.nil? ? nil : Value.normalize(metadata)]
    end

    def form_attributes(metadata)
      Value.keys!(metadata, %w[tool description autosubmit], "form webmcp")
      Tool.validate_name!(metadata["tool"])
      unless metadata["description"].is_a?(String) && !metadata["description"].empty?
        raise DefinitionError, "form webmcp description must be a nonempty string"
      end
      if metadata.key?("autosubmit") && ![true, false].include?(metadata["autosubmit"])
        raise DefinitionError, "autosubmit must be a boolean"
      end
      attrs = { "toolname" => metadata["tool"], "tooldescription" => metadata["description"] }
      attrs["toolautosubmit"] = "toolautosubmit" if metadata["autosubmit"]
      attrs
    end

    def field(options)
      options, metadata = extract(options)
      return options unless metadata
      Value.keys!(metadata, %w[param_description], "field webmcp")
      if metadata.key?("param_description")
        raise DefinitionError, "param_description must be a string" unless metadata["param_description"].is_a?(String)
        options["toolparamdescription"] = metadata["param_description"]
      end
      options
    end

    def select_options(options, html_options)
      options, metadata = extract(options)
      html_options, html_metadata = extract(html_options)
      html_options[:webmcp] = html_metadata || metadata if html_metadata || metadata
      [options, field(html_options)]
    end
  end

  module FormHelper
    def form_with(**options, &block)
      options, metadata = FormOptions.extract(options)
      options[:html] = (options[:html] || {}).merge(FormOptions.form_attributes(metadata)) if metadata
      super(**options, &block)
    end

    def self.install!
      ActionView::Helpers::FormHelper.prepend(self)
      ActionView::Helpers::FormBuilder.prepend(FormBuilderOptions)
      ActionView::Helpers::FormTagHelper.prepend(FormTagOptions)
    end
  end

  module FormBuilderOptions
    %i[text_field password_field hidden_field file_field text_area color_field search_field
       telephone_field phone_field date_field time_field datetime_field datetime_local_field
       month_field week_field url_field email_field number_field range_field].each do |method_name|
      define_method(method_name) do |attribute, options = {}|
        super(attribute, FormOptions.field(options))
      end
    end

    def check_box(attribute, options = {}, checked_value = "1", unchecked_value = "0")
      super(attribute, FormOptions.field(options), checked_value, unchecked_value)
    end

    def checkbox(attribute, options = {}, checked_value = "1", unchecked_value = "0")
      super(attribute, FormOptions.field(options), checked_value, unchecked_value)
    end

    def radio_button(attribute, value, options = {})
      super(attribute, value, FormOptions.field(options))
    end

    def select(attribute, choices = nil, options = {}, html_options = {}, &block)
      options, html_options = FormOptions.select_options(options, html_options)
      super(attribute, choices, options, html_options, &block)
    end

    def collection_select(attribute, collection, value_method, text_method, options = {}, html_options = {})
      options, html_options = FormOptions.select_options(options, html_options)
      super(attribute, collection, value_method, text_method, options, html_options)
    end

    def grouped_collection_select(attribute, collection, group_method, group_label_method, option_key_method, option_value_method, options = {}, html_options = {})
      options, html_options = FormOptions.select_options(options, html_options)
      super(attribute, collection, group_method, group_label_method, option_key_method, option_value_method, options, html_options)
    end

    %i[collection_check_boxes collection_checkboxes collection_radio_buttons].each do |method_name|
      define_method(method_name) do |attribute, collection, value_method, text_method, options = {}, html_options = {}, &block|
        options, html_options = FormOptions.select_options(options, html_options)
        super(attribute, collection, value_method, text_method, options, html_options, &block)
      end
    end

    def time_zone_select(attribute, priority_zones = nil, options = {}, html_options = {})
      options, html_options = FormOptions.select_options(options, html_options)
      super(attribute, priority_zones, options, html_options)
    end

    %i[weekday_select date_select time_select datetime_select].each do |method_name|
      define_method(method_name) do |attribute, options = {}, html_options = {}|
        options, html_options = FormOptions.select_options(options, html_options)
        super(attribute, options, html_options)
      end
    end
  end

  module FormTagOptions
    # Other scalar *_field_tag methods delegate to text_field_tag.
    %i[text_field_tag text_area_tag select_tag].each do |method_name|
      define_method(method_name) do |name, value = nil, options = {}|
        super(name, value, FormOptions.field(options))
      end
    end

    %i[check_box_tag checkbox_tag radio_button_tag].each do |method_name|
      define_method(method_name) do |*args|
        args[-1] = FormOptions.field(args.last) if args.last.is_a?(Hash)
        super(*args)
      end
    end

    private

    def html_options_for_form(url_for_options, options)
      options, metadata = FormOptions.extract(options)
      options = options.merge(FormOptions.form_attributes(metadata)) if metadata
      super(url_for_options, options)
    end
  end
end
