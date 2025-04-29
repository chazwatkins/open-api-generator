defmodule OpenAPI.Reader.State do
  @moduledoc """
  State of the reader phase of code generation

  This struct is created at the beginning of the read phase using data from the overall
  `OpenAPI.State`. It is fully managed by the read phase, and it is unlikely that client libraries
  would read or write to this struct.
  """
  require Logger

  alias OpenAPI.Reader.Config
  alias OpenAPI.Spec
  alias OpenAPI.Spec.Schema
  alias OpenAPI.Spec.Path.Parameter

  @typedoc "Decode function for raw Yaml"
  @type decoder :: decoder(term)

  @typedoc "Decode function for raw Yaml"
  @type decoder(t) :: (t, yaml -> {map, t})

  @typedoc "OpenAPI reader state"
  @type t :: %__MODULE__{
          base_file: String.t() | nil,
          base_file_path: [Spec.path_segment()],
          config: Config.t(),
          current_file: String.t() | nil,
          current_file_path: [Spec.path_segment()],
          files: %{optional(String.t()) => yaml | nil},
          last_ref_file: String.t() | nil,
          last_ref_path: [Spec.path_segment()],
          path_parameters: [Parameter.t()],
          refs: %{optional(String.t()) => map},
          schema_specs_by_path: %{Spec.full_path() => Schema.t()},
          spec: Spec.t() | nil
        }

  @typedoc "Raw Yaml input"
  @type yaml :: map | list

  defstruct [
    :base_file,
    :base_file_path,
    :config,
    :current_file,
    :current_file_path,
    :files,
    :last_ref_file,
    :last_ref_path,
    :path_parameters,
    :refs,
    :schema_specs_by_path,
    :spec
  ]

  #
  # Creation
  #

  @doc false
  @spec new(Config.t()) :: t
  def new(config) do
    %__MODULE__{
      base_file: nil,
      base_file_path: [],
      config: config,
      current_file: nil,
      current_file_path: [],
      files: files(config),
      last_ref_file: nil,
      last_ref_path: [],
      path_parameters: [],
      refs: %{},
      schema_specs_by_path: %{},
      spec: nil
    }
  end

  @spec files(Config.t()) :: %{optional(String.t()) => yaml | nil}
  defp files(config) do
    %Config{additional_files: additional_files, file: file, passed_files: passed_files} = config

    [passed_files, file, additional_files]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn filename -> {filename, nil} end)
    |> Enum.into(%{})
  end

  #
  # Manipulation
  #

  @doc false
  @spec with_path(t, yaml, Spec.path_segment(), decoder) ::
          {t, term}
  def with_path(state, yaml, path_segment, decoder) do
    %__MODULE__{
      base_file_path: original_base_file_path,
      current_file_path: original_current_file_path,
      last_ref_path: original_last_ref_path
    } = state

    state = %__MODULE__{
      state
      | base_file_path: [path_segment | original_base_file_path],
        current_file_path: [path_segment | original_current_file_path],
        last_ref_path: [path_segment | original_last_ref_path]
    }

    {state, result} = decoder.(state, yaml)

    state = %__MODULE__{
      state
      | base_file_path: original_base_file_path,
        current_file_path: original_current_file_path,
        last_ref_path: original_last_ref_path
    }

    {state, result}
  end

  @doc false
  @spec with_ref(t, yaml, decoder) :: {t, term}
  def with_ref(state, %{"$ref" => ref}, decoder) do
    [new_file, new_ref_path] = String.split(ref, "#")
    new_file = Path.join(state.current_file, new_file)
    new_ref_path_segments = String.split(new_ref_path, "/", trim: true)

    %__MODULE__{
      last_ref_file: original_last_ref_file,
      last_ref_path: original_last_ref_path
    } = state

    new_ref = "#{new_file}##{new_ref_path}"

    state = %__MODULE__{
      state
      | last_ref_file: new_file,
        last_ref_path: Enum.reverse(new_ref_path_segments)
    }

    stored_yaml = state.refs[new_ref]

    {state, yaml} =
      if stored_yaml do
        {state, stored_yaml}
      else
        state = OpenAPI.Reader.ensure_file(state, new_file)
        yaml = get_in(state.files[new_file], new_ref_path_segments)
        state = %__MODULE__{state | refs: Map.put(state.refs, new_ref, yaml)}

        {state, yaml}
      end

    {state, result} = decoder.(state, yaml)

    state = %__MODULE__{
      state
      | last_ref_file: original_last_ref_file,
        last_ref_path: original_last_ref_path
    }

    {state, result}
  end

  def with_ref(state, yaml, decoder), do: decoder.(state, yaml)

  @doc false
  @spec with_schema_ref(t, yaml, decoder) :: {t, term}
  def with_schema_ref(state, %{"$ref" => ref}, _decoder) do
    [relative_file, path_string] = String.split(ref, "#")
    absolute_file = Path.join(state.current_file, relative_file)
    path_segments = String.split(path_string, "/", trim: true)

    source_ref_full_path = {state.last_ref_file, Enum.reverse(state.last_ref_path)}
    target_ref = {:ref, {absolute_file, path_segments}}

    schema_specs_by_path = Map.put(state.schema_specs_by_path, source_ref_full_path, target_ref)
    {%__MODULE__{state | schema_specs_by_path: schema_specs_by_path}, target_ref}
  end

  def with_schema_ref(state, yaml, decoder) when is_list(yaml) do
    # Handle case where yaml is a list instead of a map
    # Take the first item in the list as a fallback
    first_item = List.first(yaml)
    with_schema_ref(state, first_item, decoder)
  end

  def with_schema_ref(state, yaml, decoder) do
    {state, schema} = decoder.(state, yaml)

    ref_full_path = {schema."$oag_last_ref_file", schema."$oag_last_ref_path"}
    schema_specs_by_path = Map.put(state.schema_specs_by_path, ref_full_path, schema)

    {%__MODULE__{state | schema_specs_by_path: schema_specs_by_path}, schema}
  end
end
