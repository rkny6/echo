import SwiftUI

/// 只选择月和日的生日选择器视图（忽略年份）
struct BirthdayPickerView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss
    
    @Binding var selectedDate: Date?
    @Binding var isPresented: Bool
    
    @State private var selectedMonth: Int
    @State private var selectedDay: Int
    
    private let calendar = Calendar.current
    private let baseYear = 2000 // 基准年份（闰年，支持2月29日）
    
    init(selectedDate: Binding<Date?>, isPresented: Binding<Bool>) {
        self._selectedDate = selectedDate
        self._isPresented = isPresented
        
        let initialDate = selectedDate.wrappedValue ?? Date()
        let components = Calendar.current.dateComponents([.month, .day], from: initialDate)
        let month = components.month ?? 1
        let day = components.day ?? 1
        self._selectedMonth = State(initialValue: month)
        self._selectedDay = State(initialValue: day)
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                // 月日选择器
                VStack(spacing: 20) {
                    HStack(spacing: 0) {
                        // 月份选择器
                        Picker("月份", selection: $selectedMonth) {
                            ForEach(1...12, id: \.self) { month in
                                Text("\(month)月")
                                    .tag(month)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                        .onChange(of: selectedMonth) { _, _ in
                            adjustDayForCurrentMonth()
                        }
                        
                        // 日选择器
                        Picker("日期", selection: $selectedDay) {
                            ForEach(1...daysInCurrentMonth(), id: \.self) { day in
                                Text("\(day)日")
                                    .tag(day)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                    }
                    .labelsHidden()
                    .padding()
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AppTheme.surfaceColor(colorScheme))
                )
                .padding()
                
                Spacer()
                
                // 底部按钮
                VStack(spacing: 12) {
                    actionButtons
                }
                .padding()
            }
            .navigationTitle("设置生日")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("确定") {
                        let date = createDateFromSelectedMonthDay()
                        selectedDate = date
                        isPresented = false
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(AppTheme.adaptiveAccentColor(colorScheme))
                }
            }
        }
    }
    
    // MARK: - 底部按钮
    
    private var actionButtons: some View {
        HStack(spacing: 12) {
            if selectedDate != nil {
                Button(action: {
                    selectedDate = nil
                    isPresented = false
                }) {
                    Text("清除生日")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.red.opacity(0.1))
                        )
                }
            }
            
            Button(action: {
                let date = createDateFromSelectedMonthDay()
                selectedDate = date
                isPresented = false
            }) {
                Text("保存生日")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AppTheme.adaptiveAccentColor(colorScheme))
                    )
            }
        }
    }
    
    // MARK: - 辅助方法
    
    private func daysInCurrentMonth() -> Int {
        guard let date = calendar.date(from: DateComponents(year: baseYear, month: selectedMonth, day: 1)) else {
            return 30
        }
        let range = calendar.range(of: .day, in: .month, for: date)
        return range?.count ?? 30
    }
    
    private func adjustDayForCurrentMonth() {
        let maxDay = daysInCurrentMonth()
        if selectedDay > maxDay {
            selectedDay = maxDay
        }
    }
    
    private func createDateFromSelectedMonthDay() -> Date {
        let components = DateComponents(year: baseYear, month: selectedMonth, day: selectedDay)
        return calendar.date(from: components) ?? Date()
    }
}
