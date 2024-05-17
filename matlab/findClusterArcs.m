function [lgspParams, lgspBounds, sumSqErrs, used2rev, failed2rev, hasBadBounds, ...
        barInfo, clusMtxs, gxyParams, imgAutoCrop, barInds, barUsed] = ...
    findClusterArcs(img, stgs, gxyName, outputParams, outputDir, starMask, stdzParams, guideImageFile)
% Main function for generating HAC clusters from an image using an
% orientation field, fitting logarithmic spirals to each cluster, and
% displaying the results
% INPUTS:
%   img: input image for which clusters and log-spirals are to be found
%   stgs: structure containing algorithm settings (see settings.m)
%   gxyName: name of galaxy image; if present, output images will be
%       written to disk using this name
%   outputParams: structure controlling what output should be produced 
%       (fields: writeImages, displayFigures, writeTxt)
%   outputDir: directory where any output files should be placed (optional,
%       defaults to current directory)
%   starMask: (optional) star mask where the lowest nonzero value indicates
%       an object and increasingly larger values indicate regions
%       progressively more aggressive in excluding stars (at the risk of 
%       excluding part of the galaxy)
%   stdzParams: (optional) parameters previously used to standardize the
%       image; this shouldn't usually be supplied but can be useful to
%       make sure a set of images (e.g., different wavebands for the same
%       galaxy) are standardized in the same way
%   guideImageFile: (optional unless using image guiding) path to image to guide
%       cluster merging step.
% OUTPUTS:
%   lgspParams: the [theta-offset, pitch-angle, initial-radius] parameters
%       of the log-spirals fitted to the clusters, one set of parameters 
%       per row
%   lgspBounds: the starting and ending theta-values of the fitted
%       log-spirals, one set of bounds per row
%   sumSqErrs: the sum of squared errors of the fitted log-spirals
%   barInfo: 
%   clusMtxs: a 3D array where nonzero elements of a page are members of a
%       particular cluster
%   gxyParams: struct with information about the fitted arcs

if nargin < 3
    gxyName = '';
end

if nargin < 4 || isempty(outputParams)
    outputParams = struct('writeImages', false, ...
        'displayFigures', true, 'writeTxt', false);
end

if nargin < 5 || isempty(outputDir)
    outputDir = ['.' filesep];
elseif ~isdir(outputDir)
    error('%s is not a directory', outputDir);
end

if nargin < 6
    starMask = [];
end

if nargin < 7
    stdzParams = [];
end

if nargin < 8 
    guideImageFile = 'NONE';
end

if ischar(stdzParams)
    stdzParams = dblStructToString(stdzParams);
end

if outputDir(end) ~= filesep
    outputDir = [outputDir filesep];
end

if stgs.mirrorLR
    fprintf('using mirrored version of img\n');
    img = fliplr(img);
    starMask = fliplr(starMask);
end

if stgs.paApproxLevel ~= 0
    fprintf('WARNING: closed-form pitch-angle approximation is experimental\n')
end

low_resolution_warn_thres = 40;

writeSettingsForEveryImage = stgs.writeSettingsForEveryImage;
sleepSecondsAfterImageWrite = stgs.sleepSecondsAfterImageWrite;
generateOrientationFieldPdf = stgs.generateOrientationFieldPdf;
clusSizeCutoff = stgs.clusSizeCutoff;
minMinorAxisLen = stgs.minMinorAxisLen;
stopThres = stgs.stopThres;
fitUsingNonUsmIVals = stgs.fitUsingNonUsmIVals;
deleteClusterContainingCenter = stgs.deleteClusterContainingCenter;


if sleepSecondsAfterImageWrite < 0
    error('parameter sleepSecondsAfterImageWrite can''t be negative\n');
elseif sleepSecondsAfterImageWrite > 0
    pause on
else
    pause off
end

outputPath = [outputDir gxyName];

if writeSettingsForEveryImage
    diary([outputPath '-S_settings.txt'])
    disp(stgs)
    diary off
    pause(sleepSecondsAfterImageWrite);
end

if stgs.imageGuidingThreshold >= 0 
    if ~strcmp(guideImageFile,'NONE') && exist(guideImageFile) == 2 %TODO test
        imageGuiding = true;
    else
        error('image guiding specified but no image was given');
    end
else
    imageGuiding = false;
end

if ~strcmp(guideImageFile,'NONE') && imageGuiding == false
    error ('guide image specified but no threshold was given');
end

tStartClus = tic;

imgOrig = img;

[img, imgNoUsm, gxyParams, fitParams, exactCtrR, exactCtrC, fromOrigImg, masked] = ...
    preprocessImage(img, stgs, starMask, stdzParams, outputPath, gxyName);
elpsFitFile = fopen([outputPath '-elps-fit-params.txt'], 'wt');
fprintf(elpsFitFile, '%s\n', dblStructToString(fitParams));
fclose(elpsFitFile);

if ~isempty(masked) && outputParams.writeImages
    imwrite(masked, [outputPath '-__star-mask-applied.png']);
    pause(sleepSecondsAfterImageWrite);
end

fprintf('calculating orientation field...\n'); tic
ofld = genOriField(img, stgs);
% fix for NaNs from zero-valued image pixels
% TODO: fix this in orientation field code
ofld(isnan(ofld)) = 0;
toc; fprintf('...done calculating orientation field\n')

ctrR = size(img, 1) / 2; 
ctrC = size(img, 2) / 2;
if stgs.useSubpixelCtr
%     ctrR = ctrR + 0.5;
%     ctrC = ctrC + 0.5;
    ctrR = exactCtrR;
    ctrC = exactCtrC;
end
gxyParams.standardizedCenterR = ctrR;
gxyParams.standardizedCenterC = ctrC;
[candRad, candTh, candScore] = findBarCandRgn(ofld, ctrR, ctrC);
[barScore, barInfo] = findBarScore(...
    imgOrig, fitParams, ctrR, ctrC, candRad, candTh, candScore, stgs);

if ~isempty(gxyName) && outputParams.writeImages
    imwrite(imgOrig, [outputPath '-A_input.png']);
    pause(sleepSecondsAfterImageWrite);
    imwrite(imgNoUsm, [outputPath '-B_autoCrop.png']);
    pause(sleepSecondsAfterImageWrite);
    imwrite(img, [outputPath '-C_preproc.png']);
    pause(sleepSecondsAfterImageWrite);
end

if isfield(gxyParams, 'fit_state') && isempty(strmatch('OK', gxyParams.fit_state))
    error(gxyParams.fit_state)
end
if gxyParams.diskMinAxsLen < minMinorAxisLen
    gxyParams.fit_state = sprintf(...
        'input rejected (resolution along minor axis too low: %2.4f < %d)',...
        gxyParams.diskMinAxsLen, minMinorAxisLen);
    error(gxyParams.fit_state);
end
if gxyParams.diskMinAxsLen < low_resolution_warn_thres
    gxyParams.warnings = [gxyParams.warnings ...
        sprintf('input:lowMinorAxisResolution:%2.2fpixels', gxyParams.diskMinAxsLen)];
end

if fitUsingNonUsmIVals
    intensityImg = imgNoUsm;
else
    intensityImg = img;
end
% Avoid empty clusters (clusters that generate a cluster matrix/image
% that sums to zero)
ofld = ofld .* repmat(intensityImg ~= 0, [1 1 2]);

if ~isempty(gxyName) && outputParams.writeImages && generateOrientationFieldPdf
    displayOrientationField(ofld, true, false);
    figSize = 1024/150;
    set(gcf, 'PaperUnits','inches');
    set(gcf, 'PaperSize', [figSize figSize]);
    set(gcf, 'PaperPositionMode', 'manual');
    set(gcf, 'PaperPosition',[0 0 figSize figSize]);
    saveas(gcf, [outputPath '-O_orientation-field.png']);
    pngLarge = rgb2gray(imread([outputPath '-O_orientation-field.png']));
    imwrite(pngLarge, [outputPath '-O_orientation-field.png'],'BitDepth',4);
    close(gcf);
end

% There were problems passing this value through the C++ code, so we resort
% to using a global instead
global failed2revDuringMerge;
failed2revDuringMerge = false;
simls = genSimilarityMtx(img, ofld, stgs, stopThres);
clusters = genHacTree(simls, intensityImg, barInfo, ctrR, ctrC, stgs);
if outputParams.displayFigures
    showClusters(clusters, size(img), clusSizeCutoff);
end
clusMtxs = hac2mtxs(clusters, intensityImg, clusSizeCutoff);
gxyParams.failed2revDuringMergeCheck = failed2revDuringMerge;

fprintf('Time for all clustering steps: \n');
toc(tStartClus)

if size(clusMtxs, 3) == 0
    gxyParams.fit_state = 'input rejected (no clusters above size threshold)';
    error(gxyParams.fit_state);
end

tStartOpt = tic;

[lgspParams, lgspBounds, sumSqErrs, used2rev, failed2rev, hasBadBounds] = fitLogSpiralsToClusters(...
    clusMtxs, ctrR, ctrC, stgs);

[barClus, lgspParams, lgspBounds, sumSqErrs, used2rev, failed2rev, hasBadBounds, clusMtxs, barAngles, barHalfLens] = ...
    extractBar(lgspParams, lgspBounds, sumSqErrs, used2rev, failed2rev, hasBadBounds, clusMtxs, barInfo);
barUsed = ~isempty(barClus);

fprintf('Time for all optimization steps: \n');
toc(tStartOpt);

gxyParams.hasDeletedCtrClus = false;
clusHasCenter = squeeze(clusMtxs(round(ctrR), round(ctrC), :)) > 0;
clusWithCenter = find(clusHasCenter);
assert(isempty(clusWithCenter) || all(size(clusWithCenter) == [1,1]))
if ~isempty(clusWithCenter)
    ctrClus = clusMtxs(:, :, clusHasCenter);
    if deleteClusterContainingCenter
        clusMtxs = clusMtxs(:, :, ~clusHasCenter);
        lgspParams = lgspParams(~clusHasCenter, :);
        lgspBounds = lgspBounds(~clusHasCenter, :);
        sumSqErrs = sumSqErrs(~clusHasCenter);
        used2rev = used2rev(~clusHasCenter);
        hasBadBounds = hasBadBounds(~clusHasCenter);
        if ~isempty(gxyName) && outputParams.writeImages
            imwrite(ctrClus, [outputPath '-__deleted_cluster.png']);
            pause(sleepSecondsAfterImageWrite);
        end
        gxyParams.warnings = [gxyParams.warnings ...
            sprintf('findClusterArcs:deletedAClusterThatIntersectedTheCenter:size=%d', ...
                nnz(ctrClus))];
        gxyParams.hasDeletedCtrClus = true;
    else
        gxyParams.warnings = [gxyParams.warnings ...
            sprintf('findClusterArcs:aClusterIntersectsTheCenter:size=%d', ...
                nnz(ctrClus))];
    end
end


hacImg = showClustersFromMtxs(cat(3, clusMtxs, barClus), size(img));
if outputParams.displayFigures
    figure; imshow(hacImg);
end

if ~isempty(gxyName) && outputParams.writeImages
    clusMask = showClustersFromMtxs(cat(3, clusMtxs, barClus), size(img), [], [], false);
    imwrite(clusMask, [outputPath '-D_clusMask.png']);
    pause(sleepSecondsAfterImageWrite);

    if getenv('WRITEBULGEMASK')
        imgSize = size(imgNoUsm);
        greyscaleClusMask = im2double(imbinarize(rgb2gray(clusMask), 0.1));
        bulgeMask = im2double(imresize(imread([outputPath '-D1_bulgeMask.png']), imgSize));
        cropMasked = imsubtract(imsubtract(imgNoUsm, greyscaleClusMask), bulgeMask);
        imwrite(cropMasked, [outputPath '-D2_cropMasked.png']);
        pause(sleepSecondsAfterImageWrite);
    end

    hacOverlay = displayLgspOverlay(hacImg, lgspParams, ctrR, ctrC, lgspBounds);
    if barUsed
        hacOverlay = addBarOverlay(hacOverlay, ctrR, ctrC, barAngles, barHalfLens, true);
    end
    imwrite(hacOverlay, [outputPath '-E_hacArcs.png'])
    pause(sleepSecondsAfterImageWrite);
end

clusOverlay = displayLgspOverlay(img, lgspParams, ctrR, ctrC, lgspBounds);
olWOrig = displayLgspOverlay(imgNoUsm, lgspParams, ctrR, ctrC, lgspBounds);
if barUsed
    clusOverlay = addBarOverlay(clusOverlay, ctrR, ctrC, barAngles, barHalfLens);
    olWOrig = addBarOverlay(olWOrig, ctrR, ctrC, barAngles, barHalfLens);
end

if outputParams.displayFigures
    figure; imshow(clusOverlay); 
    figure; imshow(olWOrig);
end

if outputParams.displayFigures
    figure;
    displayLgspPlot(lgspParams, lgspBounds, img, ctrR, ctrC,...
        barAngles, barHalfLens);
end

if ~isempty(gxyName) && outputParams.writeImages
    imwrite(olWOrig, [outputPath '-F_logSpiralArcs.png']);
    pause(sleepSecondsAfterImageWrite);
end


clusMtxsM = mergeClustersByFit(clusMtxs, ctrR, ctrC, barInfo, stgs);
if imageGuiding
    fprintf('using image guide clustering\n');
    clusMtxsM = mergeClustersByGuide(clusMtxsM, outputPath, stgs.imageGuidingThreshold, guideImageFile);
end


failed2revDuringMerge = false;
[lgspParamsM, lgspBoundsM, sumSqErrsM, used2revM, failed2revM, hasBadBoundsM] = ...
    fitLogSpiralsToClusters(clusMtxsM, ctrR, ctrC, stgs);
[barClusM, lgspParamsM, lgspBoundsM, sumSqErrsM, used2revM, failed2revM, hasBadBoundsM, clusMtxsM, barAnglesM, barHalfLensM] = ...
    extractBar(lgspParamsM, lgspBoundsM, sumSqErrsM, used2revM, failed2revM, hasBadBoundsM, clusMtxsM, barInfo);
if ~isempty(barClusM);
    if ~isempty(barClus)
        gxyParams.warnings = [gxyParams.warnings ...
            'barRegionExpandedAfterSecondaryMerging'];
        assert(all((barClus(:) == 0) | (barClusM(:) == 0)));
        barClusM = barClusM + barClus;
    else
        gxyParams.warnings = [gxyParams.warnings ...
            'barRegionDetectedOnlyAfterSecondaryMerging'];
    end
else
    barClusM = barClus;
end
barUsedM = ~isempty(barClusM);
gxyParams.failed2revDuringSecondaryMerging = failed2revDuringMerge;
    
hacImgM = showClustersFromMtxs(cat(3, clusMtxsM, barClusM), size(img));
if ~isempty(gxyName) && outputParams.writeImages
    clusOverlay = displayClusterOverlay(imgNoUsm, cat(3, clusMtxsM, barClusM));
    imwrite(clusOverlay, [outputPath '-G_imgClusters-merged.png']);
    pause(sleepSecondsAfterImageWrite);
    
    clusMask = showClustersFromMtxs(cat(3, clusMtxsM, barClusM), size(img), [], [], false);
    imwrite(clusMask, [outputPath '-H_clusMask-merged.png']);
    pause(sleepSecondsAfterImageWrite);
    
    hacOverlay = displayLgspOverlay(hacImgM, lgspParamsM, ctrR, ctrC, lgspBoundsM);
    if barUsedM
        hacOverlay = addBarOverlay(hacOverlay, ctrR, ctrC, barAnglesM, barHalfLensM, true);
    end
    imwrite(hacOverlay, [outputPath '-I_hacArcs-merged.png'])
    pause(sleepSecondsAfterImageWrite);
end
olMerged = displayLgspOverlay(imgNoUsm, lgspParamsM, ctrR, ctrC, lgspBoundsM);
if barUsedM
    olMerged = addBarOverlay(olMerged, ctrR, ctrC, barAnglesM, barHalfLensM);
end
if ~isempty(gxyName) && outputParams.writeImages
    imwrite(olMerged, [outputPath '-J_logSpiralArcs-merged.png']);
    pause(sleepSecondsAfterImageWrite);
end

if ~isempty(gxyName) && outputParams.writeImages
    clusReproj = reProject(clusMask, gxyParams.diskAxisRatio, gxyParams.diskMajAxsLen, ...
        gxyParams.diskMajAxsAngleRadians, [gxyParams.iptSz(1) - gxyParams.iptCtrXY(2) + 1, ...
        gxyParams.iptCtrXY(1)], gxyParams.iptSz);
    imwrite(clusReproj, [outputPath '-K_clusMask-reprojected.png']);
    if str2num(getenv('GENERATEFITQUALITY'))
        gxyParams = getGalfitFitQuality(imgOrig, clusReproj, outputPath, gxyParams);
    else
        gxyParams.fitQualityF1 = '';
        gxyParams.fitQualityPCC = '';
    end
end

if ~isempty(gxyName) && outputParams.writeTxt
    gxyParamsM = getGalaxyParams(lgspParamsM, lgspBoundsM, sumSqErrsM, ...
        used2revM, hasBadBoundsM, barUsedM, barInfo, barIndsM, img, ...
        clusMtxsM, stgs, gxyParams);
    writeGalaxyParams(gxyParamsM, [gxyName '-merged'], outputDir);
end

fprintf('Total time: \n')
toc(tStartClus)

% use the merged version
lgspParams = lgspParamsM;
lgspBounds = lgspBoundsM;
sumSqErrs = sumSqErrsM;
used2rev = used2revM;
failed2rev = failed2revM;
hasBadBounds = hasBadBoundsM;
barAngles = barAnglesM;
barHalfLens = barHalfLensM;
clusMtxs = clusMtxsM;
barClus = barClusM;
barUsed = barUsedM;

if ~isempty(barClus)
    clusMtxs = cat(3, clusMtxs, barClus);
    barInds = size(clusMtxs, 3);
    lgspParams = cat(1, lgspParams, [NaN NaN NaN]);
    lgspBounds = cat(1, lgspBounds, [NaN NaN]);
    sumSqErrs = [sumSqErrs; NaN];
else
    barInds = [];
end

imgAutoCrop = imgNoUsm;

function [barClus, params, bounds, errs, used2rev, failed2rev, hasBadBounds, clusMtxs, barAngles, barHalfLens] = ...
        extractBar(params, bounds, errs, used2rev, failed2rev, hasBadBounds, clusMtxs, barInfo)
    if ~isempty(barInfo) && barInfo.barDetected
        barFitErrs = zeros(size(errs));
        for ii=1:1:size(clusMtxs, 3)
            barFitErrs(ii) = calcBarFitErr(clusMtxs(:, :, ii), ...
                barInfo.stdzCtrR, barInfo.stdzCtrC, ...
                barInfo.stdzAngle, barInfo.stdzHalfLength);
        end
        isBarClus = (barFitErrs < errs);
        nBarClus = nnz(isBarClus);
        if nBarClus > 0
            if nBarClus > 1
                bcm = showClustersFromMtxs(clusMtxs(:, :, isBarClus));
                % will get overwritten if multiple bar-cluster merges for the
                % same input image
                if outputParams.writeImages
                    imwrite(bcm, [outputPath sprintf('-__%d-merged-bar-clusters.png', nBarClus)]);
                    pause(sleepSecondsAfterImageWrite);
                end
            end
            barClus = sum(clusMtxs(:, :, isBarClus), 3);
            clusMtxs = clusMtxs(:, :, ~isBarClus);
            params = params(~isBarClus, :);
            bounds = bounds(~isBarClus, :);
            errs = errs(~isBarClus);
            used2rev = used2rev(~isBarClus);
            failed2rev = failed2rev(~isBarClus);
            hasBadBounds = hasBadBounds(~isBarClus);
        else
            barClus = [];
        end
        barAngles = barInfo.stdzAngle;
        barHalfLens = barInfo.stdzHalfLength;
    else
        barClus = [];
        barAngles = [];
        barHalfLens = [];
    end
end

end
