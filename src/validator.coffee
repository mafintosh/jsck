URI = require "./uri"
deap = require "deap"

{escape, Runtime, Context} = require "./util"

module.exports = (uri, mixins) ->

  class Validator

    SCHEMA_URI = uri

    common_modules = [
      "type"
      "numeric"
      "comparison"
      "arrays"
      "objects"
      "strings"
    ]

    common = for name in common_modules
      mixin = require "./common/#{name}"
      for name, method of mixin
        Validator.prototype[name] = method

    for mixin in mixins
      for name, method of mixin
        Validator.prototype[name] = method


    constructor: (schemas...) ->
      @uris = {}
      @media_types = {}
      @unresolved = {}

      for schema in schemas
        if schema["$schema"]? && schema["$schema"] != SCHEMA_URI
          throw "This validator doesn't support this JSON schema."

        @add(schema)

    add: (schema) ->
      schema = deap.clone(schema)

      if schema.id
        # Make sure the schema id always ends with "#"
        schema.id = schema.id.replace /#?$/, "#"

      # The context keeps track of where we are in the schema while
      # we traverse it for compilation.
      context = new Context
        pointer: schema.id || "#"
        scope: schema.id || "#"

      # Make an initial pass over the schema looking for $ref fields,
      # resolving their targets for use in actual compilation.
      @compile_references schema, context

      # We try one more time to resolve $ref values, because
      # a schema may have been defined after we initially
      # tried to resolve the $ref.
      for ref, {scope, uri} of @unresolved
        if found_schema = @resolve_ref(uri, scope)
          delete @unresolved[ref]
          @register ref, found_schema
      if Object.keys(@unresolved).length > 0
        pointers = (uri for key, {uri} of @unresolved)
        throw new Error "Unresolvable $ref values: #{JSON.stringify pointers}"

      @compile(schema, context)

    register: (uri, schema) ->
      @uris[uri] = schema
      # TODO: enforce uniqueness of types
      if media_type = schema.mediaType
        if media_type != "application/json"
          @media_types[media_type] = schema

    validate: (data) ->
      @validator("#").validate(data)

    validator: (arg) ->
      if schema = @find arg
        validate: (data) =>
          errors = []
          runtime = new Runtime {errors, pointer: "#"}
          schema._test(data, runtime)
          if errors.length > 0
            for error in errors
              [base..., attribute] = error.schema.pointer.split("/")
              pointer = base.join("/")
              error.schema.definition = @resolve_ref(pointer)?[attribute]

          valid = runtime.errors.length == 0
          #console.log runtime.errors unless valid
          {valid, errors}
        toJSON: (args...) =>
          schema
      else
        throw new Error "No schema found for '#{JSON.stringify(arg)}'"

    find: (arg) ->
      if @test_type "string", arg
        uri = escape(arg)
        @uris[uri]
      else if uri = arg.uri
        uri = escape(uri)
        @uris[uri]
      else if media_type = arg.mediaType
        @media_types[media_type]
      else
        null


    resolve_ref: (uri, scope) ->
      if schema = @find(uri)
        if schema.$ref
          uri = URI.resolve(scope, schema.$ref)
          @resolve_ref(uri)
        else
          return schema
      else
        null


    compile_references: (schema, context) ->
      if schema == null
        culprit = context.pointer
        throw new Error "null is not a valid schema.  Culprit: '#{culprit}'"
      {scope, pointer} = context
      @register pointer, schema
      # This is one of the two cases where we pay attention to "id". The other is
      # top-level id declaration. Here, we treat non-JSON-pointer fragments (such
      # as "#user") as aliases.
      if schema.id && schema.id.indexOf("#") == 0
        uri = URI.resolve scope, schema.id
        schema.id = uri
        @register uri, schema

      if @test_type "object", schema
        for attribute, definition of schema
          new_context = context.child(attribute)
          switch attribute
            when "$ref"
              # turn relative refs into absolute URIs
              uri = URI.resolve(scope, definition)

              # When the URI of a $ref is a substring of the present context's URI,
              # we're in a recursive reference situation.
              # Ignore recursive references during this stage.
              if pointer.indexOf(uri + "/") != 0
                schema.$ref = uri
                if schema = @resolve_ref(uri, scope)
                  @compile_references schema, context
                else
                  # Store the unresolvable reference so we can try to resolve
                  # it again after having traversed the all schemas.
                  @unresolved[pointer] = {scope: context.scope, uri: uri}

            when "type"
              if @test_type "array", definition
                @type_refs definition, new_context
            when "properties", "patternProperties"
              # TODO: determine whether (and why) this isn't handled in the
              # basic else case.
              @dictionary_refs definition, new_context
            when "items"
              @items_refs definition, new_context
            when "additionalItems", "additionalProperties"
              @compile_references definition, context.child(attribute)
            else
              #FIXME:  this ignores all the new draft4 logical attrs like "anyOf".
              # Write test cases in official suite to prove before fixing.
              if !Validator.attributes[attribute] && @test_type("object", definition)
                @compile_references definition, context.child(attribute)
              else
                console.log attribute


    type_refs: (union, context) ->
      for schema, i in union
        if @test_type "object", schema
          @compile_references schema, context.child(i.toString())

    dictionary_refs: (properties, context) ->
      for key, schema of properties
        @compile_references schema, context.child(key)
    
    items_refs: (definition, context) ->
      if @test_type "array", definition
        for def, i in definition
          @compile_references def, context.child(i.toString())
      else
        @compile_references definition, context


    compile: (schema, context) ->
      {scope, pointer} = context
      tests = []

      # When the schema contains the $ref attribute, locate the referenced
      # schema and use in place of the present schema.
      if uri = schema.$ref
        uri = URI.resolve(scope, uri)
        if pointer.indexOf(uri) == 0
          # When the URI of a $ref is a substring of the present context's URI,
          # we're in a recursive reference situation.
          return @recursive_test(schema, context)
        schema = @find(uri)
        if !schema
          throw new Error "No schema found for $ref '#{uri}'"

      for attribute, definition of schema
        # Create a child context to track our progress into a new attribute.
        new_context = context.child(attribute)
        # Schemas may contain arbitrary fields.  We only act on those that
        # have meaning in JSON Schema.
        if spec = Validator.attributes[attribute]

          # Some validation attributes can be modified by other attributes
          # at the same level.  E.g. minimum is modified by exclusiveMinimum.
          # Here we check the schema for such auxiliary attributes and stow
          # them in the context, so the primary attribute handler can act
          # on them.
          new_context.modifiers = {}
          if spec.modifiers
            for key in spec.modifiers
              new_context.modifiers[key] = schema[key]

          # Call the attribute's handler.
          # The return value will be a function that validates a document.
          # In rare cases, the attribute handler does not return a test
          # function, because some related attribute performs the test.
          if test = @[attribute](definition, new_context)
            # TODO: Commented this out because I believe it's obsolete.
            # Delete when sure.
            #test.pointer = new_context.pointer

            tests.push test

        else
          # Unknown attribute, thus treat it as a container of schemas.
          if @test_type "object", definition
            @compile definition, new_context

      test_function = (data, runtime) =>
        for test in tests
          test(data, runtime)

      # Record the schema's test function for use by such things as
      # @recursive_test.  
      @find(pointer)?._test = test_function
      # Also record the function for schemas with "alias" ids.
      if schema.id
        uri = URI.resolve scope, schema.id
        @find(uri)?._test = test_function

      test_function


    recursive_test: (schema, {scope, pointer}) ->
      uri = URI.resolve(scope, schema.$ref)
      if schema = @find uri
        (data, runtime) =>
          schema._test(data, runtime)
      else
        throw new Error "No schema found for $ref '#{uri}'"



