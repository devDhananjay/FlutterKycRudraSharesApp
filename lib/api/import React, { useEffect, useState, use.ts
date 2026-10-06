import React, { useEffect, useState, useMemo, Fragment, useContext } from "react";
import { useRouter } from "next/router";
import { toast } from "sonner";
import FormField from "./FormField";
import { cn, waitFor } from "@/lib/utils";
import { useConditionalForm } from "@/hooks/useConditionalForm";
import { Button } from "../ui/button";
import Image from "next/image";
import loader from "@/assets/Icons/loader.gif";
import panLoader from "@/assets/UniWiseCarousel/panLoader.gif";
import { BrokerKycContext } from "@/contexts/BrokerKycContext";
import { BottomSheet } from "react-spring-bottom-sheet";
import "react-spring-bottom-sheet/dist/style.css";

const AddNominee = ({ openMobileVerified, onSuccess }) => {
    const {
        submitKyc,
        fetchWorkflowFields,
        fetchWorkflowFieldsData,
        fetchWorkflowFieldsError,
        submitKycStatus,
        submitKycError
    } = useContext(BrokerKycContext);

    const [openSheet, setOpenSheet] = useState(true);

    const add1 = fetchWorkflowFieldsData?.context?.page?.fields?.find((f) => f.name === "nominee1_add1")?.value || "";
    const add2 = fetchWorkflowFieldsData?.context?.page?.fields?.find((f) => f.name === "nominee1_add2")?.value || "";
    const pincode =
        fetchWorkflowFieldsData?.context?.page?.fields?.find((f) => f.name === "nominee1_pincode")?.value || "";
    const city = fetchWorkflowFieldsData?.context?.page?.fields?.find((f) => f.name === "nominee_1_city")?.value || "";
    const state = fetchWorkflowFieldsData?.context?.page?.fields?.find((f) => f.name === "nominee1_state")?.value || "";
    const country =
        fetchWorkflowFieldsData?.context?.page?.fields?.find((f) => f.name === "nominee1_country")?.value || "";

    const nominee_otp_in_name =
        fetchWorkflowFieldsData?.context?.page?.fields?.find((f) => f.name === "nominee_otp_in_name")?.value || "";

    const [addNominee2, setAddNominee2] = useState(false);
    const [addNominee3, setAddNominee3] = useState(false);

    const [submitError, setSubmitError] = useState("");
    const [submitSuccess, setSubmitSuccess] = useState("");

    const activeFields =
        fetchWorkflowFieldsData?.context?.page || fetchWorkflowFieldsData?.page || fetchWorkflowFieldsData || {};

    // Use the conditional form hook
    const {
        formData,
        setFormData,
        errors,
        setErrors,
        visibleFields,
        fieldVisibility,
        handleChange,
        handleBlur,
        validate,
        resetForm
    } = useConditionalForm(activeFields?.fields, activeFields?.conditionalFlow);

    // Handle skip functionality
    const handleSkip = async () => {
        setErrors({});
        await waitFor(100);
        try {
            const dataToSend = {
                nominee_status: "No",
                nominee_otp_in_name: "",
                nominee_otp_in_stamp: false
            };
            const headers = { "Content-Type": "application/json" };

            const result = await submitKyc({
                position: fetchWorkflowFieldsData?.context?.position || "",
                index: fetchWorkflowFieldsData?.context?.index || 0,
                dataToSend,
                headers,
                dataToWebhook: [
                    {
                        Stage: "Nominee",
                        noOfNominee: 0
                    }
                ]
            });

            console.log("Skip API Response:", result);

            if (result.success) {
                // Call onSuccess callback
                onSuccess(result);
            } else {
                toast.error(result.msg || "Skip failed");
            }
        } catch (err) {
            console.log("Error:", err);
            toast.error(err?.message || err?.msg || "Skip failed");
        }
    };

    // Helper function to calculate age from date of birth
    const calculateAge = (dob) => {
        if (!dob) return null;
        const birthDate = new Date(dob);
        const today = new Date();
        let age = today.getFullYear() - birthDate.getFullYear();
        const monthDiff = today.getMonth() - birthDate.getMonth();
        if (monthDiff < 0 || (monthDiff === 0 && today.getDate() < birthDate.getDate())) {
            age--;
        }
        return age;
    };

    // Check if nominees are minors (< 18 years old)
    const isNominee1Minor = useMemo(() => {
        const age = calculateAge(formData["nominee1_dob"]);
        return age !== null && age < 18;
    }, [formData["nominee1_dob"]]);

    const isNominee2Minor = useMemo(() => {
        const age = calculateAge(formData["nominee2_dob"]);
        return age !== null && age < 18;
    }, [formData["nominee2_dob"]]);

    const isNominee3Minor = useMemo(() => {
        const age = calculateAge(formData["nominee3_dob"]);
        return age !== null && age < 18;
    }, [formData["nominee3_dob"]]);

    // Automatically set nominee percentages based on number of nominees
    useEffect(() => {
        const nomineeCount = 1 + (addNominee2 ? 1 : 0) + (addNominee3 ? 1 : 0);
        let percentage1, percentage2, percentage3;

        if (nomineeCount === 1) {
            percentage1 = "100";
            percentage2 = "";
            percentage3 = "";
        } else if (nomineeCount === 2) {
            percentage1 = "50";
            percentage2 = "50";
            percentage3 = "";
        } else if (nomineeCount === 3) {
            percentage1 = "33.33";
            percentage2 = "33.33";
            percentage3 = "33.34"; // 34 to make total 100% (33+33+34=100)
        }

        // Update form data with new percentages
        const updates = [];

        if (formData.nominee_1_percentage !== percentage1) {
            updates.push({ name: "nominee_1_percentage", value: percentage1, type: "number" });
        }
        if (addNominee2 && formData.nominee_2_percentage !== percentage2) {
            updates.push({ name: "nominee_2_percentage", value: percentage2, type: "number" });
        }
        if (addNominee3 && formData.nominee3_percentage !== percentage3) {
            updates.push({ name: "nominee3_percentage", value: percentage3, type: "number" });
        }

        updates.forEach((update) => {
            handleChange({ target: update });
        });
    }, [
        addNominee2,
        addNominee3,
        formData.nominee_1_percentage,
        formData.nominee_2_percentage,
        formData.nominee3_percentage,
        handleChange
    ]);

    // Form submission
    const handleSubmit = async (e) => {
        e.preventDefault();
        setSubmitError("");
        setSubmitSuccess("");

        if (!validate()) {
            toast.error("Please fill all required fields correctly");
            return;
        }

        try {
            const result = await submitKyc({
                position: fetchWorkflowFieldsData?.context?.position || "",
                index: fetchWorkflowFieldsData?.context?.index || 0,
                dataToSend: {
                    ...formData,
                    nominee_status: "Yes",
                    nominee_otp_in_name,
                    nominee_otp_in_stamp: true
                },
                dataToWebhook: [
                    {
                        Stage: "Nominee",
                        noOfNominee: addNominee3 ? 3 : addNominee2 ? 2 : 1,
                        nominee_otp_in_name: "",
                        nominee_otp_in_stamp: false
                    }
                ],
                headers: {
                    "Content-Type": "application/json"
                }
            });

            console.log("API Response:", result);

            if (result.success) {
                // Call onSuccess callback
                if (onSuccess) {
                    onSuccess(result);
                }
            } else {
                toast.error(result.msg || "Submission failed");
                setSubmitError(result.msg || "Submission failed");
            }
        } catch (err) {
            console.log("Error:", err);
            setSubmitError(err?.message || err?.msg || "Submission failed");
            toast.error(err?.message || err?.msg || "Submission failed");
        }
    };

    // Use conditional form fields that respect visibility and conditional flow
    const fieldsToRender = useMemo(() => {
        return (
            activeFields?.fields?.filter((field) => {
                // Always include add nominee buttons regardless of fieldShow
                if (
                    [
                        "guardian_same_as_address1",
                        "guardian_same_as_address2",
                        "guardian_same_as_address3",
                        "nominee1_same_as_my_address",
                        "nominee2_same_as_my_address",
                        "nominee3_same_as_my_address",
                        "add_2_nominee",
                        "add_3_nominee"
                    ]?.includes(field.name)
                ) {
                    return true;
                }
                return field?.required || field?.mandatory || field?.fieldShow;
            }) || []
        );
        // ?.map((e) => {
        //     e.fieldShow = true;
        //     return e;
        // });
    }, [activeFields?.fields]);

    // Show loading state
    if (!activeFields?.fields) {
        return (
            <div className="min-h-screen px-4 bg-white font-Inter flex items-center justify-center">
                <Image src={loader} alt="Loading" className="h-12 object-contain mx-auto" />
            </div>
        );
    }

    return (
        <div className="min-h-screen px-4 pt-[72px] bg-white font-Inter">
            <h1 className="text-xl font-bold mb-1">Add Nominee to your account</h1>
            <p className="text-gray-700 text-sm font-medium mb-8">This is required to complete your KYC</p>

            <form onSubmit={handleSubmit}>
                <div className={cn("grid grid-cols-1")}>
                    {fieldsToRender?.map((field, index) => {
                        // Determine if this field should be shown based on nominee states
                        const isAddNominee2Button = field.name === "add_2_nominee";
                        const isAddNominee3Button = field.name === "add_3_nominee";
                        const isNominee2Field =
                            !isAddNominee2Button &&
                            !isAddNominee3Button &&
                            (field.name?.includes("e2") || field.name?.includes("_2") || field.name?.includes("two"));
                        const isNominee3Field =
                            !isAddNominee2Button &&
                            !isAddNominee3Button &&
                            (field.name?.includes("e3") || field.name?.includes("_3") || field.name?.includes("three"));

                        // Check if this is a guardian field
                        const isGuardian1Field =
                            field.name?.includes("guardian1") || field.name === "guardian_same_as_address1";
                        const isGuardian2Field =
                            field.name?.includes("guardian2") || field.name === "guardian_same_as_address2";
                        const isGuardian3Field =
                            field.name?.includes("guardian3") || field.name === "guardian_same_as_address3";

                        // Show logic:
                        // - Always show nominee 1 fields (no 2 or 3 in name)
                        // - Show "add_2_nominee" button if nominee 2 is not added yet
                        // - Show nominee 2 fields if addNominee2 is true
                        // - Show "add_3_nominee" button if nominee 2 is added but nominee 3 is not
                        // - Show nominee 3 fields if addNominee3 is true
                        // - Show guardian fields only if corresponding nominee is a minor (< 18 years)

                        // Hide guardian1 fields if nominee1 is not a minor
                        if (isGuardian1Field && !isNominee1Minor) {
                            return null;
                        }

                        // Hide guardian2 fields if nominee2 is not a minor or nominee2 not added
                        if (isGuardian2Field && (!addNominee2 || !isNominee2Minor)) {
                            return null;
                        }

                        // Hide guardian3 fields if nominee3 is not a minor or nominee3 not added
                        if (isGuardian3Field && (!addNominee3 || !isNominee3Minor)) {
                            return null;
                        }

                        // Guardian proof type conditional display
                        const nomineeOneProofType = formData["nominee_one_proof_type"];
                        const nomineeTwoProofType = formData["nominee_two_proof_type"];
                        const nomineeThreeProofType = formData["nominee_three_proof_type"];
                        // console.log({ formData, nomineeOneProofType, nomineeTwoProofType, nomineeThreeProofType });

                        // Guardian 1 PAN / Aadhaar toggle
                        if (field.name === "nominee1_pan" && !nomineeOneProofType?.toUpperCase()?.includes("PAN")) {
                            return null;
                        }
                        if (
                            field.name === "nominee1_aadhar" &&
                            !nomineeOneProofType?.toUpperCase()?.includes("AADHA")
                        ) {
                            return null;
                        }
                        // Guardian 2 PAN / Aadhaar toggle
                        if (field.name === "nominee2_pan" && !nomineeTwoProofType?.toUpperCase()?.includes("PAN")) {
                            return null;
                        }
                        if (
                            field.name === "nominee2_aadhar" &&
                            !nomineeTwoProofType?.toUpperCase()?.includes("AADHA")
                        ) {
                            return null;
                        }
                        // Guardian 3 PAN / Aadhaar toggle
                        if (field.name === "nominee3_pan" && !nomineeThreeProofType?.toUpperCase()?.includes("PAN")) {
                            return null;
                        }
                        if (
                            field.name === "nominee3_aadhar" &&
                            !nomineeThreeProofType?.toUpperCase()?.includes("AADHA")
                        ) {
                            return null;
                        }

                        // Guardian proof type conditional display
                        const guardian1ProofType = formData["guardian1_proof_type"];
                        const guardian2ProofType = formData["guardian2_proof_type"];
                        const guardian3ProofType = formData["guardian3_proof_type"];

                        // Guardian 1 PAN / Aadhaar toggle
                        if (field.name === "guardian1_pan" && !guardian1ProofType?.toUpperCase()?.includes("PAN")) {
                            return null;
                        }
                        if (
                            field.name === "guardian1_aadhar" &&
                            !guardian1ProofType?.toUpperCase()?.includes("AADHA")
                        ) {
                            return null;
                        }
                        // Guardian 2 PAN / Aadhaar toggle
                        if (field.name === "guardian2_pan" && !guardian2ProofType?.toUpperCase()?.includes("PAN")) {
                            return null;
                        }
                        if (
                            field.name === "guardian2_aadhar" &&
                            !guardian2ProofType?.toUpperCase()?.includes("AADHA")
                        ) {
                            return null;
                        }
                        // Guardian 3 PAN / Aadhaar toggle
                        if (field.name === "guardian3_pan" && !guardian3ProofType?.toUpperCase()?.includes("PAN")) {
                            return null;
                        }
                        if (
                            field.name === "guardian3_aadhar" &&
                            !guardian3ProofType?.toUpperCase()?.includes("AADHA")
                        ) {
                            return null;
                        }

                        if (isNominee2Field && !addNominee2) {
                            return null; // Hide nominee 2 fields if not added
                        }

                        if (isNominee3Field && !addNominee3) {
                            return null; // Hide nominee 3 fields if not added
                        }

                        if (isAddNominee2Button && addNominee2) {
                            return null; // Hide "add nominee 2" button once nominee 2 is added
                        }

                        if (isAddNominee3Button && (!addNominee2 || addNominee3)) {
                            return null; // Hide "add nominee 3" button if nominee 2 not added or nominee 3 already added
                        }

                        // Handle the add nominee buttons
                        if (field.name === "add_2_nominee" || field.name === "add_3_nominee") {
                            return (
                                <Fragment key={field.id || index}>
                                    <FormField
                                        {...field}
                                        value={formData[field.name]}
                                        onChange={(e) => {
                                            handleChange(e);
                                            if (field.name === "add_2_nominee") {
                                                setAddNominee2(e.target.checked);
                                            } else if (field.name === "add_3_nominee") {
                                                setAddNominee3(e.target.checked);
                                            }
                                        }}
                                        onBlur={handleBlur}
                                        errorField={errors[field.name]}
                                    />
                                </Fragment>
                            );
                        }

                        return (
                            <Fragment key={field.id || index}>
                                <FormField
                                    {...field}
                                    value={formData[field.name]}
                                    onChange={(e) => {
                                        handleChange(e);
                                        if ("nominee1_same_as_my_address" === field.name) {
                                            setFormData((prevData) => ({
                                                ...prevData,
                                                nominee1_pincode: e.target.checked ? pincode : "",
                                                nominee1_country: e.target.checked ? country : "",
                                                nominee_1_city: e.target.checked ? city : "",
                                                nominee1_state: e.target.checked ? state : "",
                                                nominee1_add1: e.target.checked ? add1 : "",
                                                nominee1_add2: e.target.checked ? add2 : ""
                                            }));
                                        } else if ("nominee2_same_as_my_address" === field.name) {
                                            setFormData((prevData) => ({
                                                ...prevData,
                                                nominee2_pincode: e.target.checked ? pincode : "",
                                                nominee2_country: e.target.checked ? country : "",
                                                nominee_2_city: e.target.checked ? city : "",
                                                nominee2_state: e.target.checked ? state : "",
                                                nominee2_add1: e.target.checked ? add1 : "",
                                                nominee2_add2: e.target.checked ? add2 : ""
                                            }));
                                        } else if ("nominee3_same_as_my_address" === field.name) {
                                            setFormData((prevData) => ({
                                                ...prevData,
                                                nominee3_pincode: e.target.checked ? pincode : "",
                                                nominee3_country: e.target.checked ? country : "",
                                                nominee3_city: e.target.checked ? city : "",
                                                nominee3_state: e.target.checked ? state : "",
                                                nominee3_add1: e.target.checked ? add1 : "",
                                                nominee3_add2: e.target.checked ? add2 : ""
                                            }));
                                        } else if ("guardian_same_as_address1" === field.name) {
                                            setFormData((prevData) => ({
                                                ...prevData,
                                                guardian1_pincode: e.target.checked ? pincode : "",
                                                guardian1_country: e.target.checked ? country : "",
                                                guardian1_city: e.target.checked ? city : "",
                                                guardian1_state: e.target.checked ? state : "",
                                                guardian1_add1: e.target.checked ? add1 : "",
                                                guardian1_add2: e.target.checked ? add2 : ""
                                            }));
                                        } else if ("guardian_same_as_address2" === field.name) {
                                            setFormData((prevData) => ({
                                                ...prevData,
                                                guardian2_pincode: e.target.checked ? pincode : "",
                                                guardian2_country: e.target.checked ? country : "",
                                                guardian2_city: e.target.checked ? city : "",
                                                guardian2_state: e.target.checked ? state : "",
                                                guardian2_add1: e.target.checked ? add1 : "",
                                                guardian2_add2: e.target.checked ? add2 : ""
                                            }));
                                        } else if ("guardian_same_as_address3" === field.name) {
                                            setFormData((prevData) => ({
                                                ...prevData,
                                                guardian3_pincode: e.target.checked ? pincode : "",
                                                guardian3_country: e.target.checked ? country : "",
                                                guardian3_city: e.target.checked ? city : "",
                                                guardian3_state: e.target.checked ? state : "",
                                                guardian3_add1: e.target.checked ? add1 : "",
                                                guardian3_add2: e.target.checked ? add2 : ""
                                            }));
                                        }
                                    }}
                                    onBlur={handleBlur}
                                    errorField={errors[field.name]}
                                    suffix={field.name?.includes("_percentage") ? "%" : ""}
                                />
                            </Fragment>
                        );
                    })}
                </div>

                {submitError && (
                    <div className="mt-4 p-3 bg-red-50 border border-red-200 rounded-xl flex items-center text-red-700">
                        <svg className="w-5 h-5 mr-2" fill="currentColor" viewBox="0 0 20 20">
                            <path
                                fillRule="evenodd"
                                d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z"
                                clipRule="evenodd"
                            />
                        </svg>
                        {submitError}
                    </div>
                )}

                {submitSuccess && (
                    <div className="mt-4 p-3 bg-green-50 border border-green-200 rounded-xl flex items-center text-green-700">
                        <svg className="w-5 h-5 mr-2" fill="currentColor" viewBox="0 0 20 20">
                            <path
                                fillRule="evenodd"
                                d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z"
                                clipRule="evenodd"
                            />
                        </svg>
                        {submitSuccess}
                    </div>
                )}

                <div className="h-40"></div>

                <div className="z-[11] fixed bottom-0 left-0 w-full bg-white p-4 shadow-[0px_8px_8px_8px_rgba(106,115,129,0.12)]">
                    <div className="flex justify-between items-center gap-3">
                        <Button
                            onClick={handleSkip}
                            variant="BUY_OUTLINE"
                            type="button"
                            disabled={submitKycStatus === "loading"}
                        >
                            {submitKycStatus === "loading" ? (
                                <Image src={panLoader} alt="icon" className="h-6 object-contain mx-auto" />
                            ) : (
                                "Skip"
                            )}
                        </Button>
                        <Button variant="BUY" type="submit" disabled={submitKycStatus === "loading"}>
                            {submitKycStatus === "loading" ? (
                                <Image src={panLoader} alt="icon" className="h-6 object-contain mx-auto" />
                            ) : (
                                <div className="flex items-center justify-center">
                                    {activeFields?.submitButton?.buttonName || "Submit"}
                                </div>
                            )}
                        </Button>
                    </div>
                    <div className="flex items-center justify-center gap-1 text-[10px] font-bold text-[#202020] whitespace-nowrap mt-2">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none">
                            <path
                                d="M19.43 3.60042C19.883 3.70002 20.2873 3.95398 20.5737 4.31882C20.8601 4.68367 21.0108 5.13672 21 5.60042V9.63042C20.9993 12.2667 20.2081 14.8423 18.7285 17.0242C17.2489 19.2062 15.149 20.8943 12.7 21.8704C12.2486 22.0391 11.7514 22.0391 11.3 21.8704C8.85105 20.8943 6.7511 19.2062 5.27151 17.0242C3.79191 14.8423 3.00066 12.2667 3 9.63042V5.56042C2.98918 5.09672 3.13987 4.64367 3.42628 4.27882C3.71268 3.91398 4.11699 3.66002 4.57 3.56042L11.57 2.01042C11.8524 1.94054 12.1476 1.94054 12.43 2.01042L19.43 3.60042Z"
                                fill="#20BF55"
                            />
                            <path
                                d="M11.23 14.7699C10.9691 14.7715 10.7179 14.671 10.53 14.4899L8.25001 12.2499C8.15628 12.157 8.08188 12.0464 8.03112 11.9245C7.98035 11.8027 7.95421 11.6719 7.95421 11.5399C7.95421 11.4079 7.98035 11.2772 8.03112 11.1554C8.08188 11.0335 8.15628 10.9229 8.25001 10.8299C8.43737 10.6437 8.69082 10.5391 8.95501 10.5391C9.21919 10.5391 9.47264 10.6437 9.66001 10.8299L11.24 12.3799L15.35 8.37994C15.4439 8.28736 15.5551 8.21417 15.6773 8.16457C15.7995 8.11497 15.9302 8.08992 16.0621 8.09085C16.1939 8.09177 16.3243 8.11866 16.4458 8.16998C16.5673 8.2213 16.6774 8.29604 16.77 8.38994C16.8626 8.48383 16.9358 8.59504 16.9854 8.71722C17.035 8.8394 17.06 8.97015 17.0591 9.10201C17.0582 9.23387 17.0313 9.36425 16.98 9.48572C16.9286 9.60719 16.8539 9.71736 16.76 9.80994L11.95 14.5399C11.7493 14.7078 11.4909 14.7904 11.23 14.7699Z"
                                fill="#EDEBEA"
                            />
                        </svg>
                        <span>100% Safe & Secure</span>
                    </div>
                </div>
            </form>
            <style>{`
                #add_2_nominee,
                #add_3_nominee,
                #add_4_nominee {
                    margin-top: 20px !important;
                    opacity: 0 !important;
                    pointer-events: none;
                }
                [for="add_2_nominee"],
                [for="add_3_nominee"],
                [for="add_4_nominee"] {
                    margin: 0px auto !important;
                    font-size: 14px !important;
                    color: #0862bc !important;
                    font-family: Inter;
                    font-size: 16px;
                    font-style: normal;
                    font-weight: 700;
                    line-height: 28px;
                }
                [for="add_2_nominee"]::before,
                [for="add_3_nominee"]::before,
                [for="add_4_nominee"]::before {
                    content: "+ ";
                }
                [for="add_2_nominee"]::after,
                [for="add_3_nominee"]::after,
                [for="add_4_nominee"]::after {
                    content: " (optional)";
                    font-size: 12px !important;
                    color: #9d9d9d !important;
                }
            `}</style>

            <BottomSheet
                open={openSheet}
                onDismiss={() => {
                    setOpenSheet(false);
                }}
                draggable={false}
                snapPoints={({ minHeight }) => [minHeight]}
            >
                <div className="px-4 py-6">
                    <div className="font-Inter text-xl font-bold text-black ">Do you want to add a nominee?</div>
                    <div className="font-Inter text-sm font-medium text-[#606060] mt-1">
                        You can add up to 3 nominees for your demat account.
                    </div>
                    <div className="font-Inter text-sm font-medium text-[#606060] mt-1">
                        You can add them now or later when the demat account is activated.
                    </div>
                    <div className="flex justify-between items-center gap-3 mt-4">
                        <Button
                            onClick={() => {
                                setOpenSheet(false);
                            }}
                            variant="BUY_OUTLINE"
                            type="button"
                            disabled={submitKycStatus === "loading"}
                        >
                            Add now
                        </Button>
                        <Button
                            onClick={handleSkip}
                            variant="BUY"
                            type="button"
                            disabled={submitKycStatus === "loading"}
                        >
                            No, add later
                        </Button>
                    </div>
                </div>
            </BottomSheet>
        </div>
    );
};

export default AddNominee;