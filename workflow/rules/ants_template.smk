

rule gen_init_avg_template:
    input: lambda wildcards: expand(config['in_images'][wildcards.channel],subject=subjects[wildcards.cohort])
    output: 'results/cohort-{cohort}/iter_0/init/init_avg_template_{channel}.nii.gz'
    params:
        dim = config['ants']['dim'],
        use_n4 = '2'
    log: 'logs/gen_init_avg_template_{channel}_{cohort}.log'
    container: config['singularity']['ants']
    shell:
        'AverageImages {params.dim} {output} {params.use_n4} {input} &> {log}'

rule get_existing_template:
    input: lambda wildcards: config['init_template'][wildcards.channel]
    output: 'results/cohort-{cohort}/iter_0/init/existing_template_{channel}.nii.gz'
    log: 'logs/get_existing_template_{channel}_{cohort}.log'
    shell: 'cp -v {input} {output} &> {log}'


rule set_init_template:
    input:
        'results/cohort-{cohort}/iter_0/init/init_avg_template_{channel}.nii.gz' if config['init_template'] == None else 'results/cohort-{cohort}/iter_0/init/existing_template_{channel}.nii.gz'
    params: 
        cmd = lambda wildcards, input, output:
                'ResampleImageBySpacing {dim} {input} {output} {vox_dims}'.format(
                        dim = config['ants']['dim'], input = input, output = output,
                        vox_dims=' '.join([str(d) for d in config['resample_vox_dims']]))
                     if config['resample_init_template'] else f"cp -v {input} {output}"
    output: 'results/cohort-{cohort}/iter_0/template_{channel}.nii.gz'
    log: 'logs/set_init_template_{channel}_{cohort}.log'
    container: config['singularity']['ants']
    shell: '{params.cmd} &> {log}'

rule reg_to_template:
    input: 
        template = lambda wildcards: ['results/cohort-{cohort}/iter_{iteration}/template_{channel}.nii.gz'.format(
                                iteration=iteration,channel=channel,cohort=wildcards.cohort) for iteration,channel in itertools.product([int(wildcards.iteration)-1],channels)],
        target = lambda wildcards: [config['in_images'][channel] for channel in channels]
    params:
        out_prefix = 'results/cohort-{cohort}/iter_{iteration}/sub-{subject}_',
        base_opts = '-d {dim} --float 1 --verbose 1 --random-seed {random_seed}'.format(dim=config['ants']['dim'],random_seed=config['ants']['random_seed']),
        intensity_opts = config['ants']['intensity_opts'],
        init_translation = lambda wildcards, input: '-r [{template},{target},1]'.format(template=input.template[0],target=input.target[0]),
        linear_multires = '-c [{reg_iterations},1e-6,10] -f {shrink_factors} -s {smoothing_factors}'.format(
                                reg_iterations = config['ants']['linear']['reg_iterations'],
                                shrink_factors = config['ants']['linear']['shrink_factors'],
                                smoothing_factors = config['ants']['linear']['smoothing_factors']),
        deform_model = '-t {deform_model}'.format(deform_model = config['ants']['deform']['transform_model']),
        deform_multires = '-c [{reg_iterations},1e-9,10] -f {shrink_factors} -s {smoothing_factors}'.format(
                                reg_iterations = config['ants']['deform']['reg_iterations'],
                                shrink_factors = config['ants']['deform']['shrink_factors'],
                                smoothing_factors = config['ants']['deform']['smoothing_factors']),
        linear_metric = lambda wildcards, input: ['-m MI[{template},{target},1,32,Regular,0.25]'.format(
                                template=template,target=target) for template,target in zip(input.template,input.target) ],
        deform_metric = lambda wildcards, input: ['-m {metric}[{template},{target},1,4]'.format(
                                metric=config['ants']['deform']['sim_metric'],
                                template=template, target=target) for template,target in zip(input.template,input.target) ]
    output:
        warp = 'results/cohort-{cohort}/iter_{iteration}/sub-{subject}_1Warp.nii.gz',
        invwarp = 'results/cohort-{cohort}/iter_{iteration}/sub-{subject}_1InverseWarp.nii.gz',
        affine = 'results/cohort-{cohort}/iter_{iteration}/sub-{subject}_0GenericAffine.mat',
    log: 'logs/reg_to_template/cohort-{cohort}/iter_{iteration}_sub-{subject}.log'
    threads: 16
    resources:
        mem_mb = 16000, # right now these are on the high-end -- could implement benchmark rules to do this at some point..
        time = 3*60 # 3 hrs
    container: config['singularity']['ants']
    shell: 
        'ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS={threads} '
        'antsRegistration {params.base_opts} {params.intensity_opts} '
        '{params.init_translation} ' #initial translation
        '-t Rigid[0.1] {params.linear_metric} {params.linear_multires} ' # rigid registration
        '-t Affine[0.1] {params.linear_metric} {params.linear_multires} ' # affine registration
        '{params.deform_model} {params.deform_metric} {params.deform_multires} '  # deformable registration
        '-o {params.out_prefix} &> {log}'


rule warp_to_template:
    input: 
        template = lambda wildcards: 'results/cohort-{cohort}/iter_{iteration}/template_{{channel}}.nii.gz'.format(iteration=int(wildcards.iteration)-1, channel=wildcards.channel,cohort=wildcards.cohort),
        target = lambda wildcards: config['in_images'][wildcards.channel],
        warp = 'results/cohort-{cohort}/iter_{iteration}/sub-{subject}_1Warp.nii.gz',
        affine = 'results/cohort-{cohort}/iter_{iteration}/sub-{subject}_0GenericAffine.mat',
    params:
        base_opts = '-d {dim} --float 1 --verbose 1'.format(dim=config['ants']['dim']),
    output:
        warped = 'results/cohort-{cohort}/iter_{iteration}/sub-{subject}_WarpedToTemplate_{channel}.nii.gz'
    log: 'logs/warp_to_template/cohort-{cohort}/iter_{iteration}_sub-{subject}_{channel}_{cohort}.log'
    threads: 1
    container: config['singularity']['ants']
    shell: 
        'ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS={threads} '
        'antsApplyTransforms {params.base_opts} -i {input.target} -o {output.warped} -r {input.template} -t {input.warp} -t {input.affine} &> {log}'

rule avg_warped:
    input: 
        targets = lambda wildcards: expand('results/cohort-{cohort}/iter_{iteration}/sub-{subject}_WarpedToTemplate_{channel}.nii.gz',subject=subjects[wildcards.cohort],iteration=wildcards.iteration,channel=wildcards.channel,cohort=wildcards.cohort,allow_missing=True)
    params:
        dim = config['ants']['dim'],
        use_n4 = '2'
    output: 'results/cohort-{cohort}/iter_{iteration}/shape_update/avg_warped_{channel}.nii.gz'
    group: 'shape_update'
    log: 'logs/avg_warped/cohort-{cohort}/iter_{iteration}_{channel}.log'
    container: config['singularity']['ants']
    shell:
        'AverageImages {params.dim} {output} {params.use_n4} {input} &> {log}'
       
rule avg_inverse_warps:
    input:
        warps = lambda wildcards: expand('results/cohort-{cohort}/iter_{iteration}/sub-{subject}_1Warp.nii.gz',subject=subjects[wildcards.cohort],iteration=wildcards.iteration,cohort=wildcards.cohort,allow_missing=True),
    params:
        dim = config['ants']['dim'],
        use_n4 = '0'
    output: 
        invwarp = 'results/cohort-{cohort}/iter_{iteration}/shape_update/avg_inverse_warps.nii.gz'
    group: 'shape_update'
    log: 'logs/avg_inverse_warps/cohort-{cohort}/iter_{iteration}.log'
    container: config['singularity']['ants']
    shell:
        'AverageImages {params.dim} {output} {params.use_n4} {input} &> {log}'
         
rule scale_by_gradient_step:
    input: 'results/cohort-{cohort}/iter_{iteration}/shape_update/avg_inverse_warps.nii.gz'
    params:
        dim = config['ants']['dim'],
        gradient_step = '-{gradient_step}'.format(gradient_step = config['ants']['shape_update']['gradient_step'])
    output: 'results/cohort-{cohort}/iter_{iteration}/shape_update/avg_inverse_warps_scaled.nii.gz'
    group: 'shape_update'
    log: 'logs/scale_by_gradient_step/cohort-{cohort}/iter_{iteration}.log'
    container: config['singularity']['ants']
    shell:
        'MultiplyImages {params.dim} {input} {params.gradient_step} {output} &> {log}' 

rule avg_affine_transforms:
    input: 
        affine = lambda wildcards: expand('results/cohort-{cohort}/iter_{iteration}/sub-{subject}_0GenericAffine.mat',subject=subjects[wildcards.cohort],iteration=wildcards.iteration,cohort=wildcards.cohort,allow_missing=True),
    params:
        dim = config['ants']['dim']
    output:
        affine = 'results/cohort-{cohort}/iter_{iteration}/shape_update/avg_affine.mat'
    group: 'shape_update'
    log: 'logs/avg_affine_transforms/cohort-{cohort}/iter_{iteration}.log'
    container: config['singularity']['ants']
    shell:
        'AverageAffineTransformNoRigid {params.dim} {output} {input} &> {log}'

rule transform_inverse_warp:
    input:
        affine = 'results/cohort-{cohort}/iter_{iteration}/shape_update/avg_affine.mat',
        invwarp = 'results/cohort-{cohort}/iter_{iteration}/shape_update/avg_inverse_warps_scaled.nii.gz',
        ref = lambda wildcards: 'results/cohort-{cohort}/iter_{iteration}/shape_update/avg_warped_{channel}.nii.gz'.format(iteration=wildcards.iteration,channel=channels[0],cohort=wildcards.cohort) #just use 1st channel as ref
    params:
        dim = '-d {dim}'.format(dim = config['ants']['dim'])
    output: 
        invwarp = 'results/cohort-{cohort}/iter_{iteration}/shape_update/avg_inverse_warps_scaled_transformed.nii.gz'
    group: 'shape_update'
    log: 'logs/transform_inverse_warp/cohort-{cohort}/iter_{iteration}.log'
    container: config['singularity']['ants']
    shell:
        'antsApplyTransforms {params.dim} -e vector -i {input.invwarp} -o {output} -t [{input.affine},1] -r {input.ref} --verbose 1 &> {log}'

rule apply_template_update:
    input:
        template =  'results/cohort-{cohort}/iter_{iteration}/shape_update/avg_warped_{channel}.nii.gz',
        affine = 'results/cohort-{cohort}/iter_{iteration}/shape_update/avg_affine.mat',
        invwarp = 'results/cohort-{cohort}/iter_{iteration}/shape_update/avg_inverse_warps_scaled_transformed.nii.gz'
    params:
        dim = '-d {dim}'.format(dim = config['ants']['dim'])
    output:
        template =  'results/cohort-{cohort}/iter_{iteration}/template_{channel}.nii.gz'
    log: 'logs/apply_template_update/cohort-{cohort}/iter_{iteration}_{channel}_{cohort}.log'
    group: 'shape_update'
    container: config['singularity']['ants']
    shell:
        'antsApplyTransforms {params.dim} --float 1 --verbose 1 -i {input.template} -o {output.template} -t [{input.affine},1] '
        ' -t {input.invwarp} -t {input.invwarp} -t {input.invwarp} -t {input.invwarp} -r {input.template} &> {log}' #apply warp 4 times


