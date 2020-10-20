"""Repackages jar files using Jar Jar Links."""

_CLWB_TEMPLATES_REPACKAGE_RULES = """
com.google.devtools.intellij.blaze.plugin.clwb.resources.fileTemplates fileTemplates
"""

_G3PLUGINS_REPACKAGE_RULES = """
com.google.common com.google.repackaged.common
com.google.gson com.google.repackaged.gson
com.google.idea.common.experiments com.google.idea.common.experiments
com.google.protobuf com.google.repackaged.protobuf
com.google.thirdparty com.google.repackaged.thirdparty
io.grpc io.grpc.repackaged
net.sf.cglib net.sf.cglib.repackaged
org.mozilla.javascript org.mozilla.javascript.repackaged
org.objectweb.asm org.objectweb.asm.repackaged
"""

_REPACKAGE_RULES = {
    "clwb_templates": _CLWB_TEMPLATES_REPACKAGE_RULES,
    "g3plugins": _G3PLUGINS_REPACKAGE_RULES,
}

_RepackagedJarsInfo = provider(fields = {
    "jars": "a dict of original jar Files to repackaged jar Files",
})

def _repackage_single_jar(ctx, rules_file, input_jar):
    ext = "." + input_jar.extension if input_jar.extension else ""
    name_without_ext = input_jar.basename[:-len(ext)]
    output_jar = ctx.actions.declare_file(
        "repackaged_%s_%s_%s%s" % (name_without_ext, ctx.attr.rules, str(hash(input_jar.short_path)), ext),
    )

    args = ctx.actions.args()
    args.add_all(["--rules", rules_file, "--input", input_jar, "--output", output_jar])
    ctx.actions.run(
        inputs = [input_jar, rules_file, ctx.file._repackager],
        outputs = [output_jar],
        executable = ctx.executable._java,
        arguments = [
            "-jar",
            ctx.file._repackager.path,
            args,
        ],
        progress_message = "Repackaging " + input_jar.short_path + " to " + output_jar.short_path,
        mnemonic = "Repackaging",
    )
    return output_jar

def _get_target_jars(target):
    """Find a provider exposing java compilation/outputs data."""

    # Both the GWT and the non-GWT common.collect package get included in the g3plugins deps. They
    # have different versions of a few classes, which results in a one-definition error. This is a
    # known issue, so the conflicting classes are whitelisted. But since we repackage the jar, the
    # whitelist doesn't apply to our renamed classes. So we'll just manually exclude the GWT jar.
    # http://google3/social/boq/conformance/onedefinition/one_definition_whitelist?l=9168&rcl=147615702
    if (target.label.package == "third_party/java_src/google_common/current/java/com/google/common/collect" and
        target.label.name == "collect-gwt"):
        return depset()

    # Different-but-similar versions of these are included in the plugin API, so we'll just use those.
    if (target.label.package.startswith("third_party/java/jsr305_annotations/")):
        return depset()

    jars = []
    if JavaInfo in target and target[JavaInfo].outputs:
        jars += [jar.class_jar for jar in target[JavaInfo].outputs.jars]
    return depset(jars)

def _repackaged_jar_aspect_impl(target, ctx):
    rules_file = ctx.actions.declare_file("repackage_rules_" + ctx.attr.rules + ".txt")
    ctx.actions.write(rules_file, _REPACKAGE_RULES[ctx.attr.rules])

    jars = dict()

    targets = []
    for attr_name in dir(ctx.rule.attr):
        attr_val = getattr(ctx.rule.attr, attr_name, None)
        if not attr_val:
            continue
        attr_type = type(attr_val)
        if attr_type == type(target):
            targets.append(attr_val)
        elif attr_type == type([]):
            targets += [list_val for list_val in attr_val if type(list_val) == type(target)]

    for mytarget in targets:
        if _RepackagedJarsInfo in mytarget:
            jars.update(mytarget[_RepackagedJarsInfo].jars)

    for jar in _get_target_jars(target).to_list():
        jars[jar] = _repackage_single_jar(ctx, rules_file, jar)

    return struct(providers = [_RepackagedJarsInfo(jars = jars)])

_repackaged_jar_aspect = aspect(
    attr_aspects = ["*"],
    attrs = {
        "_java": attr.label(
            default = Label("//third_party/java/jdk:java"),
            cfg = "host",
            executable = True,
        ),
        "_repackager": attr.label(
            default = Label("//build_defs:repackager_deploy.jar"),
            allow_single_file = True,
        ),
        "rules": attr.string(values = _REPACKAGE_RULES.keys()),
    },
    required_aspect_providers = [JavaInfo],
    implementation = _repackaged_jar_aspect_impl,
)

def _repackaged_jar(ctx):
    alljars = dict()
    compile = depset()
    runtime = depset()
    for dep in ctx.attr.deps:
        compile = depset(transitive = [compile, dep[JavaInfo].full_compile_jars])
        runtime = depset(transitive = [runtime, dep[JavaInfo].transitive_runtime_jars])
        alljars.update(dep[_RepackagedJarsInfo].jars)

    repackaged_compile = [alljars[jar] for jar in compile.to_list() if jar in alljars]
    repackaged_runtime = [alljars[jar] for jar in runtime.to_list() if jar in alljars]

    # Wrap each repackaged runtime jar in a JavaInfo provider.
    repackaged_transtive_runtime = [
        JavaInfo(output_jar = repackaged_runtime_jar, compile_jar = repackaged_runtime_jar)
        for repackaged_runtime_jar in repackaged_runtime
    ]

    # Wrap each repacked top-level compile time jar in a JavaInfo provider.
    # Use the repacked runtime JavaInfo providers as dependencies to keep the
    # transitive repacked runtime jars.
    repackaged_full_compile = [
        JavaInfo(
            output_jar = repackaged_compile_jar,
            compile_jar = repackaged_compile_jar,
            deps = repackaged_transtive_runtime,
        )
        for repackaged_compile_jar in repackaged_compile
    ]

    # Return a merged provider. The merged JavaInfo has:
    # - repacked compile time jars as top level compile time jars
    # - repacked transitive runtime jars as transitive runtime jars
    java_info = java_common.merge(repackaged_full_compile)
    return struct(providers = [java_info])

_internal_repackaged_jar_rule = rule(
    attrs = {
        "deps": attr.label_list(
            aspects = [_repackaged_jar_aspect],
            providers = [JavaInfo],
        ),
        "rules": attr.string(values = _REPACKAGE_RULES.keys()),
    },
    implementation = _repackaged_jar,
)

def repackaged_jar(name, deps, rules, visibility = None, exported_plugins = []):
    internal_name = "_internal_repackaged_" + name
    _internal_repackaged_jar_rule(
        name = internal_name,
        deps = deps,
        rules = rules,
        visibility = ["//visibility:private"],
    )
    native.java_library(
        name = name,
        visibility = visibility,
        exported_plugins = exported_plugins,
        exports = [internal_name],
    )

def repackage_deploy_jar(name, input_jar, output, rules, visibility = None):
    native.genrule(
        name = name,
        cmd = ("$(location //build_defs:repackager)" +
               " --rules '$(location {0})' --input '$<' --output '$@'").format(
            rules,
        ),
        srcs = [input_jar],
        outs = [output],
        visibility = visibility,
        tools = [
            rules,
            "//build_defs:repackager",
        ],
    )
