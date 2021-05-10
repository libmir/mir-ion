project('ion_meson_example', 'd',
    version: '2.0.0',
    meson_version: '>=0.46',
    default_options : [
        'b_staticpic=true',
        'b_pie=true',
        'warning_level=2',
    ]
)

description = 'Ion Meson Example.'

add_global_link_arguments('-Wl,--no-demangle', language : 'd')

add_global_arguments([
    '-dip1008',
    '--d-version=mir_secure_memory',
], language: 'd')

add_project_arguments([
    '-lowmem',
], language: 'd')

subprojects = [
    'mir-core',
    'mir-algorithm',
    'mir-cpuid',
    'mir-ion',
]

required_deps = []
foreach p : subprojects
    required_deps += dependency(p, fallback : [p, 'this_dep'])
endforeach

ion_example_import_dirs = include_directories(
    # 'views/',
)

ion_example_dir = include_directories('source')

ion_example_src = [
    'source/meson_test.d',
]

ion_example_lib = shared_library('ion_meson_example',
    ion_example_src,
    include_directories: ion_example_dir,
    install: true,
    dependencies: required_deps,
    d_import_dirs: ion_example_import_dirs,
    d_module_versions: ['mir_secure_memory'],
)

ion_example_dep = declare_dependency(
    link_whole: [ion_example_lib],
    include_directories: ion_example_dir,
    dependencies: required_deps,
)
